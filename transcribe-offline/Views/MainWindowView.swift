import SwiftUI

struct MainWindowView: View {
    @StateObject private var historyManager = TranscriptionHistoryManager.shared
    @StateObject private var audioRecorder = AudioRecorder()
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var statusBarController: StatusBarController

    @State private var selectedTranscriptionId: UUID?
    @State private var showSettings = false
    @State private var currentRecordingPlaceholderId: UUID?

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
                        Task {
                            // Set the current placeholder ID to the transcription being retried
                            currentRecordingPlaceholderId = transcription.id

                            // Create TranscriptionResult from the stored transcription
                            let transcriptResult = TranscriptionResult(
                                text: transcription.transcript,
                                duration: parseDuration(transcription.duration),
                                wordCount: transcription.wordCount,
                                language: nil
                            )
                            await audioRecorder.retrySummarizationForTranscript(transcriptResult)
                        }
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

        case .transcribing:
            // Update placeholder to show transcribing status
            updatePlaceholder(title: "Transcribing...", summary: "Converting audio to text...")

        case .summarizing:
            // Update placeholder to show summarizing status
            updatePlaceholder(title: "Generating summary...", summary: "Creating structured notes from transcript...", status: .inProgress)

        case .complete(let summary, let transcript):
            // Replace placeholder with final transcription
            Task {
                await replacePlaceholderWithFinal(summary: summary, transcript: transcript)
            }

        case .error(let message, let transcript):
            // Update placeholder with error state and preserve transcript
            if let transcript = transcript {
                updatePlaceholderWithError(message: message, transcript: transcript)
            } else {
                updatePlaceholder(title: "Error", summary: message)
            }

        default:
            break
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
            summaryProvider: summary.provider
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

    private func updatePlaceholder(title: String, summary: String, status: SummaryStatus = .pending) {
        guard let placeholderId = currentRecordingPlaceholderId,
              let index = historyManager.transcriptions.firstIndex(where: { $0.id == placeholderId }) else {
            return
        }

        var updated = historyManager.transcriptions[index]
        updated.title = title
        updated.summary = summary
        updated.duration = formatDuration(audioRecorder.duration)
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

    private func replacePlaceholderWithFinal(summary: SummaryResult, transcript: TranscriptionResult) async {
        guard let placeholderId = currentRecordingPlaceholderId else {
            // Fallback: save normally if no placeholder exists
            await saveToHistory(summary: summary, transcript: transcript)
            return
        }

        // Find the existing transcription to preserve its date
        let existingTranscription = historyManager.transcriptions.first(where: { $0.id == placeholderId })
        let preservedDate = existingTranscription?.date ?? summary.timestamp
        let preservedDuration = existingTranscription?.duration ?? formatDuration(audioRecorder.duration)

        // Generate title from summary using LLM
        let title = await generateTitle(from: summary.markdown)

        let finalTranscription = Transcription(
            id: placeholderId,  // Reuse the placeholder ID
            title: title,
            date: preservedDate,  // Preserve original date
            duration: preservedDuration,  // Preserve original duration
            summary: summary.markdown,
            transcript: transcript.text,
            wordCount: transcript.wordCount,
            isPlaceholder: false,
            summaryStatus: .completed,
            summaryProvider: summary.provider
        )

        historyManager.update(finalTranscription)
        selectedTranscriptionId = finalTranscription.id
        currentRecordingPlaceholderId = nil
        showSettings = false
    }
}

#Preview {
    MainWindowView()
        .frame(width: 1000, height: 700)
}
