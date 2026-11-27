import SwiftUI
import AVFoundation

struct MainWindowView: View {
    @StateObject private var historyManager = TranscriptionHistoryManager.shared
    @StateObject private var audioRecorder = AudioRecorder()
    @ObservedObject private var transcriptionQueue = TranscriptionQueue.shared
    @ObservedObject private var summarizationQueue = SummarizationQueue.shared
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var statusBarController: StatusBarController

    @State private var selectedTranscriptionId: UUID?
    @State private var showSettings = false
    @State private var currentRecordingPlaceholderId: UUID?
    @State private var queueMonitorTimer: Timer?
    @State private var showDeleteConfirmation = false
    @State private var transcriptionToDelete: Transcription?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ToolbarView(
                state: audioRecorder.state,
                duration: audioRecorder.duration,
                progress: getProgress(),
                onStartRecording: {
                    Task {
                        // Dismiss settings when starting a new recording
                        showSettings = false

                        // If we're in complete or error state, reset first
                        if case .complete = audioRecorder.state {
                            await audioRecorder.startNewRecording()
                        } else if case .error = audioRecorder.state {
                            await audioRecorder.startNewRecording()
                        }
                        await audioRecorder.startRecording()
                    }
                },
                onStopRecording: {
                    Task {
                        await audioRecorder.stopRecording()
                    }
                },
                onOpenSettings: {
                    selectedTranscriptionId = nil
                    showSettings = true
                }
            )

            // Main content area with sidebar
            HStack(spacing: 0) {
                // Sidebar
                TranscriptionSidebarView(
                    historyManager: historyManager,
                    selectedId: $selectedTranscriptionId,
                    showSettings: $showSettings
                )
                .layoutPriority(1)  // Give sidebar priority to maintain its width

                // Separator
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)

                // Content area
                ContentAreaView(
                    state: audioRecorder.state,
                    duration: audioRecorder.duration,
                    progress: getProgress(),
                    progressMessage: TranscriptionService.shared.progressMessage,
                    selectedTranscription: selectedTranscription,
                    showSettings: showSettings,
                    onRetry: {
                        Task {
                            await audioRecorder.retryTranscription()
                        }
                    },
                    onRetryForTranscription: { transcription in
                        // Retry by enqueuing to SummarizationQueue (same as auto-chain flow)
                        Logger.shared.info("Retrying summarization for transcription \(transcription.id)", category: .transcription)

                        var updated = transcription
                        updated.summaryStatus = .summarizationQueued
                        updated.title = "Waiting for summarization"
                        updated.summary = "Queued for retry..."

                        // Enqueue to SummarizationQueue (same as auto-chain does)
                        let summaryId = summarizationQueue.enqueue(
                            transcriptionId: transcription.id,
                            transcript: transcription.transcript,
                            diarizedTranscript: transcription.diarizedTranscript,
                            speakerCount: transcription.speakerCount,
                            wordCount: transcription.wordCount
                        )

                        Logger.shared.info("Enqueued retry summarization with ID \(summaryId)", category: .transcription)

                        // Link transcription to queue (critical for monitoring)
                        updated.summarizationQueueId = summaryId

                        // Save - queue monitor will handle state updates from here
                        historyManager.update(updated)
                        selectedTranscriptionId = transcription.id
                    },
                    onDelete: { transcription in
                        // Show confirmation dialog
                        transcriptionToDelete = transcription
                        showDeleteConfirmation = true
                    }
                )
                .frame(minWidth: 400)  // Ensure content area has reasonable minimum
            }
        }
        .frame(minWidth: 700, minHeight: 600)
        .onChange(of: audioRecorder.state) { oldState, newState in
            handleStateChange(from: oldState, to: newState)
            handleStatusBarButton(for: newState)
        }
        .onAppear {
            startQueueMonitoring()
            #if DEBUG
            reprocessRecordingFromLaunchArguments()
            #endif
        }
        .onDisappear {
            stopQueueMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
            selectedTranscriptionId = nil
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StartRecordingFromStatusBar"))) { _ in
            Task {
                // Same logic as the in-app start button
                showSettings = false

                if case .complete = audioRecorder.state {
                    await audioRecorder.startNewRecording()
                } else if case .error = audioRecorder.state {
                    await audioRecorder.startNewRecording()
                }
                await audioRecorder.startRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("StopRecordingFromStatusBar"))) { _ in
            Task {
                await audioRecorder.stopRecording()
            }
        }
        .alert("Delete Transcription", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                transcriptionToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let transcription = transcriptionToDelete {
                    Logger.shared.info("Deleting transcription: \(transcription.title)", category: .transcription)
                    historyManager.delete(transcription)
                    selectedTranscriptionId = nil
                    transcriptionToDelete = nil
                }
            }
        } message: {
            if let transcription = transcriptionToDelete {
                Text("Are you sure you want to delete '\(transcription.title)'? This action cannot be undone.")
            }
        }
    }

    // MARK: - Status Bar Management

    private func handleStatusBarButton(for state: RecorderState) {
        switch state {
        case .idle, .complete, .error:
            // Blue play button - ready to start recording
            statusBarController.updateState(.idle)
        case .recording:
            // Red stop button - currently recording
            statusBarController.updateState(.recording)
        case .stopped, .transcribing, .summarizing:
            // Gray processing indicator - processing
            statusBarController.updateState(.processing)
        }
    }

    // MARK: - Computed Properties

    private var selectedTranscription: Transcription? {
        guard let id = selectedTranscriptionId else { return nil }
        return historyManager.transcriptions.first(where: { $0.id == id })
    }

    private func getProgress() -> Double {
        if case .transcribing(let progress) = audioRecorder.state {
            return progress
        }
        return 0
    }

    // MARK: - State Change Handling

    private func handleStateChange(from oldState: RecorderState, to newState: RecorderState) {
        switch newState {
        case .recording:
            // Create placeholder when recording starts
            createPlaceholder()

        case .stopped:
            // Recording just stopped, will transition to idle after enqueueing
            break

        case .idle:
            // Check if recording just finished and was enqueued
            // Accept transition from either .stopped or .recording (in case state changes happen quickly)
            if let queueId = audioRecorder.lastEnqueuedTranscriptionId,
               let placeholderId = currentRecordingPlaceholderId {
                Logger.shared.info("Linking placeholder \(placeholderId) to queue \(queueId)", category: .transcription)
                linkPlaceholderToQueue(transcriptionQueueId: queueId, duration: audioRecorder.lastRecordingDuration)
            }

        case .error(let message, let transcript):
            // Update placeholder with error state and preserve transcript
            if let transcript = transcript {
                updatePlaceholderWithError(message: message, transcript: transcript)
            } else {
                updateCurrentPlaceholder(title: "Error", summary: message, status: .failed)
            }

        default:
            break
        }
    }

    // MARK: - Queue Monitoring

    private func startQueueMonitoring() {
        // Monitor queues every 200ms
        queueMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            self.updateAllPlaceholdersFromQueues()
        }
    }

    private func stopQueueMonitoring() {
        queueMonitorTimer?.invalidate()
        queueMonitorTimer = nil
    }

    private func updateAllPlaceholdersFromQueues() {
        // Update all transcriptions based on their queue IDs
        for transcription in historyManager.transcriptions {
            // Check transcription queue
            if let transcriptionQueueId = transcription.transcriptionQueueId {
                if let queueItem = transcriptionQueue.queue.first(where: { $0.id == transcriptionQueueId }) {
                    updatePlaceholderForTranscriptionItem(transcription: transcription, queueItem: queueItem)
                } else {
                    // Orphaned queue ID - queue item no longer exists
                    Logger.shared.warning("Transcription \(transcription.id) has orphaned transcriptionQueueId \(transcriptionQueueId), clearing", category: .transcription)
                    var updated = transcription
                    updated.transcriptionQueueId = nil
                    historyManager.update(updated)
                }
            }
            // Check summarization queue
            else if let summarizationQueueId = transcription.summarizationQueueId {
                if let queueItem = summarizationQueue.queue.first(where: { $0.id == summarizationQueueId }) {
                    updatePlaceholderForSummarizationItem(transcription: transcription, queueItem: queueItem)
                } else {
                    // Orphaned queue ID - queue item no longer exists
                    Logger.shared.warning("Transcription \(transcription.id) has orphaned summarizationQueueId \(summarizationQueueId), clearing", category: .transcription)
                    var updated = transcription
                    updated.summarizationQueueId = nil
                    historyManager.update(updated)
                }
            }
        }

        // Clean up orphaned queue items (queue items with no corresponding transcription)
        // This happens when a transcription is deleted while its queue item is still processing

        // Check transcription queue for orphans
        for queueItem in transcriptionQueue.queue {
            let hasCorrespondingTranscription = historyManager.transcriptions.contains { transcription in
                transcription.transcriptionQueueId == queueItem.id
            }
            if !hasCorrespondingTranscription {
                Logger.shared.warning("Found orphaned transcription queue item \(queueItem.id), removing", category: .transcription)
                transcriptionQueue.remove(id: queueItem.id)
            }
        }

        // Check summarization queue for orphans
        for queueItem in summarizationQueue.queue {
            let hasCorrespondingTranscription = historyManager.transcriptions.contains { transcription in
                transcription.summarizationQueueId == queueItem.id
            }
            if !hasCorrespondingTranscription {
                Logger.shared.warning("Found orphaned summarization queue item \(queueItem.id), removing", category: .transcription)
                summarizationQueue.remove(id: queueItem.id)
            }
        }
    }

    private func updatePlaceholderForTranscriptionItem(transcription: Transcription, queueItem: TranscriptionQueue.QueueItem) {
        // Defensive check: Verify transcription still exists (might have been deleted)
        guard historyManager.transcriptions.contains(where: { $0.id == transcription.id }) else {
            Logger.shared.warning("Transcription \(transcription.id) was deleted, cleaning up queue item \(queueItem.id)", category: .transcription)
            transcriptionQueue.remove(id: queueItem.id)
            return
        }

        var updated = transcription

        switch queueItem.state {
        case .pending:
            updated.title = "Waiting to transcribe"
            updated.summary = "In transcription queue..."
            updated.summaryStatus = .transcribing
            updated.transcriptionProgress = 0.0

            // Check if anything actually changed before updating
            if transcription.title == updated.title &&
               transcription.summary == updated.summary &&
               transcription.summaryStatus == updated.summaryStatus &&
               transcription.transcriptionProgress == updated.transcriptionProgress {
                return  // No changes, skip update to avoid disk I/O spam
            }

        case .processing:
            let progressPercent = Int(queueItem.progress * 100)
            updated.title = "Transcribing... \(progressPercent)%"
            updated.summary = "Converting audio to text..."
            updated.summaryStatus = .transcribing
            updated.transcriptionProgress = queueItem.progress

            // Check if anything actually changed before updating
            if transcription.title == updated.title &&
               transcription.summary == updated.summary &&
               transcription.summaryStatus == updated.summaryStatus &&
               transcription.transcriptionProgress == updated.transcriptionProgress {
                return  // No changes, skip update to avoid disk I/O spam
            }

        case .completed:
            if let result = queueItem.result {
                Logger.shared.info("Transcription completed, auto-chaining to summarization for \(transcription.id)", category: .transcription)
                // Auto-chain to summarization
                updated.transcript = result.text
                updated.diarizedTranscript = result.diarizedTranscript?.formattedText
                updated.speakerCount = result.speakerCount
                updated.wordCount = result.wordCount
                updated.summaryStatus = .summarizationQueued
                updated.transcriptionQueueId = nil

                // Enqueue summarization
                let summaryId = summarizationQueue.enqueue(
                    transcriptionId: queueItem.id,
                    transcript: result.text,
                    diarizedTranscript: result.diarizedTranscript?.formattedText,
                    speakerCount: result.speakerCount,
                    wordCount: result.wordCount
                )
                Logger.shared.info("Enqueued summarization with ID \(summaryId) for transcription \(transcription.id)", category: .transcription)
                updated.summarizationQueueId = summaryId
                updated.title = "Waiting for summarization"
                updated.summary = "Transcription complete, queued for summarization..."

                // Remove from transcription queue
                transcriptionQueue.remove(id: queueItem.id)
            }

        case .failed:
            updated.title = "Transcription failed"
            updated.summary = queueItem.error ?? "Unknown error"
            updated.summaryStatus = .failed
            updated.isPlaceholder = false
            updated.transcriptionQueueId = nil
            transcriptionQueue.remove(id: queueItem.id)
        }

        historyManager.update(updated)
    }

    private func updatePlaceholderForSummarizationItem(transcription: Transcription, queueItem: SummarizationQueue.QueueItem) {
        // Defensive check: Verify transcription still exists (might have been deleted)
        guard historyManager.transcriptions.contains(where: { $0.id == transcription.id }) else {
            Logger.shared.warning("Transcription \(transcription.id) was deleted, cleaning up queue item \(queueItem.id)", category: .transcription)
            summarizationQueue.remove(id: queueItem.id)
            return
        }

        var updated = transcription

        switch queueItem.state {
        case .pending:
            updated.title = "Waiting for summarization"
            updated.summary = "In summarization queue..."
            updated.summaryStatus = .inProgress

            // Check if anything actually changed before updating
            if transcription.title == updated.title &&
               transcription.summary == updated.summary &&
               transcription.summaryStatus == updated.summaryStatus {
                return  // No changes, skip update to avoid disk I/O spam
            }

        case .processing:
            updated.title = "Generating summary..."
            updated.summary = "Creating structured notes from transcript..."
            updated.summaryStatus = .inProgress

            // Check if anything actually changed before updating
            if transcription.title == updated.title &&
               transcription.summary == updated.summary &&
               transcription.summaryStatus == updated.summaryStatus {
                return  // No changes, skip update to avoid disk I/O spam
            }

        case .completed:
            if let result = queueItem.result {
                // Replace with final transcription
                Task {
                    await self.replacePlaceholderWithFinal(
                        placeholderId: transcription.id,
                        summary: result,
                        transcript: transcription.transcript,
                        wordCount: transcription.wordCount,
                        duration: transcription.duration,
                        date: transcription.date,
                        diarizedTranscript: transcription.diarizedTranscript,
                        speakerCount: transcription.speakerCount
                    )
                }
                summarizationQueue.remove(id: queueItem.id)
            }

        case .failed:
            updated.title = "Transcription complete (summarization failed)"
            updated.summary = queueItem.error ?? "Unknown error"
            updated.summaryStatus = .failed
            updated.isPlaceholder = false
            updated.summarizationQueueId = nil
            historyManager.update(updated)
            selectedTranscriptionId = updated.id
            summarizationQueue.remove(id: queueItem.id)
        }

        if queueItem.state != .completed {
            historyManager.update(updated)
        }
    }

    private func saveToHistory(summary: SummaryResult, transcript: TranscriptionResult) async {
        // Generate title from summary using LLM
        let title = await generateTitle(from: summary.markdown)

        // Format duration as MM:SS or HH:MM:SS
        let duration = formatDuration(audioRecorder.duration)

        let transcription = Transcription(
            title: title,
            date: summary.timestamp,
            duration: duration,
            summary: summary.markdown,
            transcript: transcript.text,
            wordCount: transcript.wordCount,
            summaryStatus: .completed,
            summaryProvider: summary.provider,
            wasInterrupted: audioRecorder.wasInterrupted,
            interruptionReason: audioRecorder.interruptionReason
        )

        historyManager.add(transcription)

        // Select the newly created transcription
        selectedTranscriptionId = transcription.id
        showSettings = false
    }

    private func generateTitle(from markdown: String) async -> String {
        // Try to generate title using LLM
        do {
            let title = try await SummarizationManager.shared.generateTitle(from: markdown)
            return title
        } catch {
            // If title generation fails, fall back to timestamp
            Logger.shared.warning("Title generation failed, using timestamp fallback: \(error.localizedDescription)", category: .transcription)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Recording \(formatter.string(from: Date()))"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private func parseDuration(_ durationString: String) -> TimeInterval {
        let components = durationString.split(separator: ":").compactMap { Int($0) }

        if components.count == 3 {
            // HH:MM:SS format
            return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
        } else if components.count == 2 {
            // MM:SS format
            return TimeInterval(components[0] * 60 + components[1])
        }

        return 0
    }

    // MARK: - Placeholder Management

    private func createPlaceholder() {
        let placeholder = Transcription(
            title: "Recording in progress...",
            date: Date(),
            duration: "0:00",
            summary: "Recording audio...",
            transcript: "",
            wordCount: 0,
            isPlaceholder: true,
            summaryStatus: .pending
        )

        historyManager.add(placeholder)
        currentRecordingPlaceholderId = placeholder.id
        selectedTranscriptionId = placeholder.id
        showSettings = false
    }

    #if DEBUG
    /// Test builds only: run a kept recording through the full pipeline again, as if just recorded.
    /// Launch with: -reprocessMixed <wav> [-reprocessMicrophone <wav> -reprocessSystem <wav>]
    private func reprocessRecordingFromLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let mixedPath = defaults.string(forKey: "reprocessMixed") else { return }

        let mixedURL = URL(fileURLWithPath: mixedPath)
        guard FileManager.default.fileExists(atPath: mixedURL.path) else {
            Logger.shared.error("Reprocess: recording not found", category: .transcription)
            return
        }

        var tracks: RecordingTracks? = nil
        if let micPath = defaults.string(forKey: "reprocessMicrophone"),
           let systemPath = defaults.string(forKey: "reprocessSystem") {
            tracks = RecordingTracks(microphoneURL: URL(fileURLWithPath: micPath), systemURL: URL(fileURLWithPath: systemPath))
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: mixedURL.path)
        let recordedAt = attributes?[.modificationDate] as? Date ?? Date()
        let duration = (try? AVAudioFile(forReading: mixedURL)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0

        Logger.shared.info("Reprocessing kept recording: \(mixedURL.lastPathComponent)", category: .transcription)

        // Enqueue and add the linked placeholder together, so queue monitoring never sees one without the other
        let queueId = transcriptionQueue.enqueue(audioFileURL: mixedURL, tracks: tracks, recordingDuration: duration)
        let placeholder = Transcription(
            title: "Waiting to transcribe",
            date: recordedAt,
            duration: formatDuration(duration),
            summary: "In transcription queue...",
            transcript: "",
            wordCount: 0,
            isPlaceholder: true,
            summaryStatus: .transcribing,
            transcriptionQueueId: queueId
        )

        historyManager.add(placeholder)
        selectedTranscriptionId = placeholder.id
        showSettings = false
    }
    #endif

    private func linkPlaceholderToQueue(transcriptionQueueId: UUID, duration: TimeInterval) {
        guard let placeholderId = currentRecordingPlaceholderId,
              let index = historyManager.transcriptions.firstIndex(where: { $0.id == placeholderId }) else {
            return
        }

        var updated = historyManager.transcriptions[index]
        updated.transcriptionQueueId = transcriptionQueueId
        updated.duration = formatDuration(duration)
        updated.title = "Waiting to transcribe"
        updated.summary = "In transcription queue..."
        updated.summaryStatus = .transcribing

        historyManager.update(updated)

        // Clear current placeholder ID - it's now tracked by queue ID
        currentRecordingPlaceholderId = nil
    }

    private func updateCurrentPlaceholder(title: String, summary: String, status: SummaryStatus) {
        guard let placeholderId = currentRecordingPlaceholderId,
              let index = historyManager.transcriptions.firstIndex(where: { $0.id == placeholderId }) else {
            return
        }

        var updated = historyManager.transcriptions[index]
        updated.title = title
        updated.summary = summary
        updated.summaryStatus = status

        historyManager.update(updated)
    }

    private func updatePlaceholderWithError(message: String, transcript: TranscriptionResult) {
        guard let placeholderId = currentRecordingPlaceholderId,
              let index = historyManager.transcriptions.firstIndex(where: { $0.id == placeholderId }) else {
            return
        }

        var updated = historyManager.transcriptions[index]
        updated.title = "Transcription complete (summarization failed)"
        updated.summary = message  // No longer needs ⚠️ prefix
        updated.transcript = transcript.text
        updated.wordCount = transcript.wordCount
        updated.duration = formatDuration(audioRecorder.duration)
        updated.isPlaceholder = false  // No longer a placeholder, it's a real transcription
        updated.summaryStatus = .failed

        historyManager.update(updated)
        selectedTranscriptionId = updated.id
        currentRecordingPlaceholderId = nil
    }

    private func replacePlaceholderWithFinal(
        placeholderId: UUID,
        summary: SummaryResult,
        transcript: String,
        wordCount: Int,
        duration: String,
        date: Date,
        diarizedTranscript: String? = nil,
        speakerCount: Int? = nil
    ) async {
        // Generate title from summary using LLM
        let title = await generateTitle(from: summary.markdown)

        let finalTranscription = Transcription(
            id: placeholderId,  // Reuse the placeholder ID
            title: title,
            date: date,  // Preserve original date
            duration: duration,  // Preserve original duration
            summary: summary.markdown,
            transcript: transcript,
            wordCount: wordCount,
            isPlaceholder: false,
            summaryStatus: .completed,
            summaryProvider: summary.provider,
            diarizedTranscript: diarizedTranscript,
            speakerCount: speakerCount
        )

        historyManager.update(finalTranscription)
        selectedTranscriptionId = finalTranscription.id
        showSettings = false
    }
}

#Preview {
    MainWindowView()
        .frame(width: 1000, height: 700)
}
