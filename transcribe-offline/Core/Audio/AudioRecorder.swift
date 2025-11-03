import Foundation
import AVFoundation
import Combine
import Accelerate

enum RecorderState: Equatable {
    case idle
    case recording
    case stopped
    case transcribing(progress: Double)
    case summarizing
    case complete(summary: SummaryResult, transcript: TranscriptionResult)
    case error(String, transcript: TranscriptionResult?)

    static func == (lhs: RecorderState, rhs: RecorderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.stopped, .stopped), (.summarizing, .summarizing):
            return true
        case (.transcribing(let a), .transcribing(let b)):
            return a == b
        case (.complete(let a, _), .complete(let b, _)):
            return a.markdown == b.markdown
        case (.error(let a, _), .error(let b, _)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
class AudioRecorder: NSObject, ObservableObject {
    @Published var state: RecorderState = .idle
    @Published var duration: TimeInterval = 0

    // ScreenCaptureKit recorder (macOS 15+) - captures both system audio + microphone
    private var screenCaptureRecorder: ScreenCaptureKitRecorder?
    private var screenCaptureSystemURL: URL?
    private var screenCaptureMicURL: URL?

    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    // Audio settings optimized for Whisper transcription and file size
    // Whisper.cpp resamples all audio to 16kHz internally, so recording at 16kHz
    // provides optimal transcription quality with minimal file size.
    //
    // File size comparison (1 hour recording):
    // - Original (48kHz, Float32, Stereo): ~1.38 GB
    // - Current (16kHz, Int16, Mono): ~115 MB (92% reduction!)
    //
    // Processing: 16kHz Float32 (easier to work with)
    // Storage: 16kHz Int16 (50% smaller than Float32)
    // Transcription quality: No degradation - 16kHz is ideal for speech
    private let sampleRate: Double = 16000
    private let systemChannelCount: UInt32 = 1  // Mono for system audio (meetings are typically mono)
    private let microphoneChannelCount: UInt32 = 1  // Mono for microphone

    // Services
    private let logger = Logger.shared
    private let transcriptionService = TranscriptionService.shared
    private let summarizationManager = SummarizationManager.shared

    // Current results
    @Published var currentTranscription: TranscriptionResult?
    @Published var currentSummary: SummaryResult?

    // MARK: - Initialization

    override init() {
        super.init()
        logger.info("AudioRecorder initialized", category: .audio)
        currentTranscription = nil

        // Clean up old audio files on launch
        Task {
            await cleanupOldAudioFiles()
        }
    }

    // MARK: - Public Interface

    func startRecording() async {
        guard state == .idle else {
            logger.warning("Start recording called but state is not idle: \(state)", category: .audio)
            return
        }

        do {
            logger.info("Starting recording (system audio + microphone)", category: .audio)

            // Use ScreenCaptureKit for all recording (macOS 15+)
            // This captures both system audio and microphone in a synchronized manner
            // and works even when Google Meet is using the microphone
            try await startScreenCaptureRecording()

            state = .recording
            recordingStartTime = Date()
            startDurationTimer()

            logger.info("✅ Recording started successfully", category: .audio)

        } catch {
            let errorMessage = "Failed to start recording: \(error.localizedDescription)"
            logger.error(errorMessage, category: .audio)
            state = .error(errorMessage, transcript: nil)
        }
    }

    // MARK: - ScreenCaptureKit Recording (macOS 15+)

    private func startScreenCaptureRecording() async throws {
        logger.info("Starting ScreenCaptureKit recording (system audio + microphone)...", category: .audio)

        logger.info("Creating temporary WAV files...", category: .file)
        screenCaptureSystemURL = createTempWAVFile(suffix: "system")
        screenCaptureMicURL = createTempWAVFile(suffix: "microphone")

        // Create ScreenCaptureKit recorder with separate output files
        screenCaptureRecorder = ScreenCaptureKitRecorder(
            sampleRate: sampleRate,
            systemOutputURL: screenCaptureSystemURL!,
            microphoneOutputURL: screenCaptureMicURL!
        )

        // Start recording - this will request Screen Recording + Microphone permissions
        try await screenCaptureRecorder?.startRecording()

        logger.info("✅ ScreenCaptureKit recording started", category: .audio)
    }

    // MARK: - Recording Control

    func stopRecording() async {
        guard state == .recording else {
            logger.warning("Stop recording called but not currently recording", category: .audio)
            return
        }

        logger.info("Stopping audio recording...", category: .audio)

        do {
            // Stop ScreenCaptureKit recorder if active
            if screenCaptureRecorder != nil {
                try await screenCaptureRecorder?.stopRecording()
                screenCaptureRecorder = nil
            }

            stopDurationTimer()
            state = .stopped

            logger.info("Recording duration: \(String(format: "%.1f", duration)) seconds", category: .audio)

            // Log file sizes
            logAudioFileSizes()

            // Start transcription
            // With ScreenCaptureKit, transcribe available files
            if let systemURL = screenCaptureSystemURL, let micURL = screenCaptureMicURL {
                // Both files available - mix and transcribe
                do {
                    let mixedURL = try mixAudioFiles(systemURL: systemURL, microphoneURL: micURL)
                    await startSingleTranscription(for: mixedURL)
                } catch {
                    let errorMessage = "Audio mixing failed: \(error.localizedDescription)"
                    logger.error(errorMessage, category: .audio)
                    state = .error(errorMessage, transcript: nil)
                }
            } else if let micURL = screenCaptureMicURL {
                // Mic only (system audio disabled)
                logger.info("Transcribing microphone-only recording", category: .transcription)
                await startSingleTranscription(for: micURL)
            } else if let systemURL = screenCaptureSystemURL {
                // System only (mic disabled)
                logger.info("Transcribing system-audio-only recording", category: .transcription)
                await startSingleTranscription(for: systemURL)
            }

        } catch {
            let errorMessage = "Failed to stop recording: \(error.localizedDescription)"
            logger.error(errorMessage, category: .audio)
            state = .error(errorMessage, transcript: nil)
        }
    }

    func retryTranscription() async {
        // Check if we have a transcript in the error state (summarization failed)
        if case .error(_, let transcript) = state, let transcript = transcript {
            // We have a transcript, so just retry summarization
            logger.info("Retrying summarization with existing transcript", category: .transcription)
            await startSummarization(transcript: transcript)
            return
        }

        logger.warning("Retry transcription called but no transcript available in error state", category: .transcription)
    }

    func retrySummarizationForTranscript(_ transcript: TranscriptionResult) async {
        logger.info("Retrying summarization for stored transcript", category: .transcription)
        await startSummarization(transcript: transcript)
    }

    func startNewRecording() async {
        logger.info("Starting new recording session", category: .audio)
        state = .idle
        currentTranscription = nil
        currentSummary = nil
        screenCaptureSystemURL = nil
        screenCaptureMicURL = nil
        duration = 0
    }

    // MARK: - Transcription

    private func startSingleTranscription(for audioURL: URL) async {
        logger.info("Starting single transcription for: \(audioURL.lastPathComponent)", category: .transcription)

        // PRIVACY: Always cleanup audio files when this function exits (success or failure)
        defer {
            cleanupAudioFile(at: audioURL)

            if let systemURL = screenCaptureSystemURL {
                cleanupAudioFile(at: systemURL)
            }
            if let micURL = screenCaptureMicURL {
                cleanupAudioFile(at: micURL)
            }
        }

        guard transcriptionService.isSetupValid() else {
            let errorMessage = "Transcription setup invalid:\n\(transcriptionService.getSetupStatus())"
            logger.error(errorMessage, category: .transcription)
            state = .error(errorMessage, transcript: nil)
            return
        }

        // Retry logic: Attempt transcription up to 3 times
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                logger.info("Retrying transcription (attempt \(attempt)/\(maxAttempts))...", category: .transcription)
                try? await Task.sleep(for: .seconds(1)) // Wait 1 second between retries
            }

            // Monitor transcription progress
            let progressTask = Task {
                while transcriptionService.isTranscribing {
                    await MainActor.run {
                        state = .transcribing(progress: transcriptionService.progress)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }

            do {
                let result = try await transcriptionService.transcribe(audioFileURL: audioURL)
                progressTask.cancel()

                logger.info("Transcription completed successfully", category: .transcription)
                logger.info("Transcribed \(result.wordCount) words in \(String(format: "%.2f", result.duration)) seconds", category: .transcription)

                currentTranscription = result

                // Start summarization automatically
                await startSummarization(transcript: result)

                return // Success - exit function (defer will cleanup audio)

            } catch {
                progressTask.cancel()
                lastError = error

                // Log error diagnostics (for debugging) - NO audio content
                logTranscriptionErrorDiagnostics(audioURL: audioURL, error: error, attempt: attempt)

                if attempt < maxAttempts {
                    logger.warning("Transcription attempt \(attempt) failed: \(error.localizedDescription)", category: .transcription)
                } else {
                    // All attempts failed
                    logger.error("Transcription failed after \(maxAttempts) attempts: \(error.localizedDescription)", category: .transcription)
                }
            }
        }

        // All retry attempts failed - show error to user
        if let error = lastError {
            let errorMessage = "Transcription failed after \(maxAttempts) attempts: \(error.localizedDescription)"
            state = .error(errorMessage, transcript: nil)
        }

        // Note: defer block will cleanup audio files automatically
    }

    private func logTranscriptionErrorDiagnostics(audioURL: URL, error: Error, attempt: Int) {
        // Log diagnostic info for debugging (NOT audio content)
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0
            let fileSizeMB = Double(fileSize) / (1024 * 1024)

            logger.error("Transcription error diagnostics (attempt \(attempt)):", category: .transcription)
            logger.error("  File: \(audioURL.lastPathComponent)", category: .transcription)
            logger.error("  Size: \(String(format: "%.2f", fileSizeMB)) MB", category: .transcription)
            logger.error("  Error: \(error.localizedDescription)", category: .transcription)

            // Try to get audio file duration
            if let audioFile = try? AVAudioFile(forReading: audioURL) {
                let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                logger.error("  Duration: \(String(format: "%.2f", duration)) seconds", category: .transcription)
                logger.error("  Sample Rate: \(audioFile.fileFormat.sampleRate) Hz", category: .transcription)
                logger.error("  Channels: \(audioFile.fileFormat.channelCount)", category: .transcription)
            }
        } catch {
            logger.error("Failed to gather error diagnostics: \(error.localizedDescription)", category: .transcription)
        }
    }

    // MARK: - Audio Mixing

    private func mixAudioFiles(systemURL: URL, microphoneURL: URL) throws -> URL {
        logger.info("Mixing audio files...", category: .audio)

        // Create output URL for mixed audio
        let mixedURL = createTempWAVFile(suffix: "mixed")

        // Load both audio files
        let systemFile = try AVAudioFile(forReading: systemURL)
        let micFile = try AVAudioFile(forReading: microphoneURL)

        // Use the higher sample rate of the two files
        let systemFormat = systemFile.processingFormat
        let micFormat = micFile.processingFormat
        let targetSampleRate = max(systemFormat.sampleRate, micFormat.sampleRate)

        // Create output format (mono at target sample rate)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioMixing", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output format"])
        }

        // Create output file
        let outputFile = try AVAudioFile(forWriting: mixedURL, settings: outputFormat.settings)

        // Determine the longer duration
        let systemFrames = systemFile.length
        let micFrames = micFile.length
        let systemDuration = Double(systemFrames) / systemFormat.sampleRate
        let micDuration = Double(micFrames) / micFormat.sampleRate
        let maxDuration = max(systemDuration, micDuration)
        let maxFrames = AVAudioFrameCount(maxDuration * targetSampleRate)

        logger.info("Mixing: System=\(String(format: "%.2f", systemDuration))s, Mic=\(String(format: "%.2f", micDuration))s", category: .audio)

        // Create buffers for reading
        let bufferSize: AVAudioFrameCount = 4096
        guard let systemBuffer = AVAudioPCMBuffer(pcmFormat: systemFormat, frameCapacity: bufferSize),
              let micBuffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: bufferSize),
              let mixedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else {
            throw NSError(domain: "AudioMixing", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffers"])
        }

        // Create converters if sample rates differ
        var systemConverter: AVAudioConverter?
        var micConverter: AVAudioConverter?

        if systemFormat.sampleRate != targetSampleRate {
            systemConverter = AVAudioConverter(from: systemFormat, to: outputFormat)
        }
        if micFormat.sampleRate != targetSampleRate {
            micConverter = AVAudioConverter(from: micFormat, to: outputFormat)
        }

        // Mix audio in chunks
        var totalFramesProcessed: AVAudioFrameCount = 0

        while totalFramesProcessed < maxFrames {
            // Read from system audio
            systemBuffer.frameLength = 0
            if systemFile.framePosition < systemFile.length {
                try systemFile.read(into: systemBuffer)
            }

            // Read from microphone
            micBuffer.frameLength = 0
            if micFile.framePosition < micFile.length {
                try micFile.read(into: micBuffer)
            }

            // If both are empty, we're done
            if systemBuffer.frameLength == 0 && micBuffer.frameLength == 0 {
                break
            }

            // Convert and mix
            mixedBuffer.frameLength = bufferSize

            // Get pointers to the output buffer
            guard let mixedChannelData = mixedBuffer.floatChannelData else { continue }
            let mixedPtr = mixedChannelData[0]

            // Zero out the mixed buffer
            memset(mixedPtr, 0, Int(bufferSize) * MemoryLayout<Float>.size)

            let framesToProcess = min(bufferSize, maxFrames - totalFramesProcessed)

            // Add system audio
            if systemBuffer.frameLength > 0 {
                if let converter = systemConverter {
                    // Convert if needed
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else { continue }
                    var error: NSError?
                    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                        outStatus.pointee = .haveData
                        return systemBuffer
                    }
                    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                    if let channelData = convertedBuffer.floatChannelData {
                        let srcPtr = channelData[0]
                        vDSP_vadd(mixedPtr, 1, srcPtr, 1, mixedPtr, 1, vDSP_Length(framesToProcess))
                    }
                } else {
                    // Direct copy
                    if let channelData = systemBuffer.floatChannelData {
                        let srcPtr = channelData[0]
                        vDSP_vadd(mixedPtr, 1, srcPtr, 1, mixedPtr, 1, vDSP_Length(min(systemBuffer.frameLength, framesToProcess)))
                    }
                }
            }

            // Add microphone audio
            if micBuffer.frameLength > 0 {
                if let converter = micConverter {
                    // Convert if needed
                    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize) else { continue }
                    var error: NSError?
                    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                        outStatus.pointee = .haveData
                        return micBuffer
                    }
                    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                    if let channelData = convertedBuffer.floatChannelData {
                        let srcPtr = channelData[0]
                        vDSP_vadd(mixedPtr, 1, srcPtr, 1, mixedPtr, 1, vDSP_Length(framesToProcess))
                    }
                } else {
                    // Direct copy
                    if let channelData = micBuffer.floatChannelData {
                        let srcPtr = channelData[0]
                        vDSP_vadd(mixedPtr, 1, srcPtr, 1, mixedPtr, 1, vDSP_Length(min(micBuffer.frameLength, framesToProcess)))
                    }
                }
            }

            // Write mixed buffer to output
            mixedBuffer.frameLength = framesToProcess
            try outputFile.write(from: mixedBuffer)

            totalFramesProcessed += framesToProcess
        }

        logger.info("Audio mixing completed: \(mixedURL.lastPathComponent)", category: .audio)
        return mixedURL
    }

    private func startSummarization(transcript: TranscriptionResult) async {
        logger.info("Starting summarization...", category: .transcription)
        state = .summarizing

        do {
            let summary = try await summarizationManager.summarize(transcript: transcript.text)

            logger.info("Summarization completed successfully", category: .transcription)
            logger.info("Summary generated in \(String(format: "%.2f", summary.processingTime))s by \(summary.provider)", category: .transcription)

            currentSummary = summary
            state = .complete(summary: summary, transcript: transcript)

            // Note: Export is now handled by user action in the UI

        } catch {
            let errorMessage = "Summarization failed: \(error.localizedDescription)"
            logger.error(errorMessage, category: .transcription)
            state = .error(errorMessage, transcript: transcript)
            // Transcript is preserved in error state so user can access it
        }
    }

    // MARK: - Private Setup

    private func createTempWAVFile(suffix: String = "") -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffixPart = suffix.isEmpty ? "" : "_\(suffix)"
        let filename = "capture_\(timestamp)\(suffixPart).wav"
        return tempDir.appendingPathComponent(filename)
    }

    private func startDurationTimer() {
        duration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                guard let self = self, let startTime = self.recordingStartTime else { return }
                self.duration = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func logAudioFileSizes() {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0

        // Log ScreenCaptureKit file sizes (separate system + microphone)
        if let scSystemURL = screenCaptureSystemURL, fileManager.fileExists(atPath: scSystemURL.path) {
            if let attributes = try? fileManager.attributesOfItem(atPath: scSystemURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
                let sizeString = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                logger.info("ScreenCaptureKit system audio file size: \(sizeString)", category: .file)
            }
        }
        if let scMicURL = screenCaptureMicURL, fileManager.fileExists(atPath: scMicURL.path) {
            if let attributes = try? fileManager.attributesOfItem(atPath: scMicURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
                let sizeString = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
                logger.info("ScreenCaptureKit microphone file size: \(sizeString)", category: .file)
            }
        }

        // Log total if recording both (always true now)
        if totalSize > 0 && screenCaptureSystemURL != nil {
            let totalString = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
            logger.info("Total audio file size: \(totalString)", category: .file)
        }

        // Calculate and log per-minute rate
        if totalSize > 0 && duration > 0 {
            let bytesPerMinute = Double(totalSize) / (duration / 60.0)
            let rateString = ByteCountFormatter.string(fromByteCount: Int64(bytesPerMinute), countStyle: .file)
            logger.info("Recording rate: \(rateString)/minute", category: .file)
        }
    }

    private func cleanupAudioFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.info("Cleaned up audio file: \(url.lastPathComponent)", category: .file)
        } catch {
            logger.warning("Failed to delete audio file: \(error.localizedDescription)", category: .file)
        }
    }

    private func cleanupOldAudioFiles() async {
        let tempDir = FileManager.default.temporaryDirectory
        let maxAge: TimeInterval = 24 * 60 * 60 // 24 hours

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )

            let wavFiles = fileURLs.filter { $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix("capture_") }

            guard !wavFiles.isEmpty else {
                logger.debug("No old audio files to clean up", category: .file)
                return
            }

            let now = Date()
            var deletedCount = 0

            for fileURL in wavFiles {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let creationDate = attributes[.creationDate] as? Date {
                    let age = now.timeIntervalSince(creationDate)

                    if age > maxAge {
                        try? FileManager.default.removeItem(at: fileURL)
                        logger.debug("Deleted old audio file: \(fileURL.lastPathComponent) (age: \(String(format: "%.1f", age/3600))h)", category: .file)
                        deletedCount += 1
                    }
                }
            }

            if deletedCount > 0 {
                logger.info("Cleaned up \(deletedCount) old audio file(s)", category: .file)
            }

        } catch {
            logger.warning("Failed to clean up old audio files: \(error.localizedDescription)", category: .file)
        }
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case systemAudioPermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please grant permission in System Settings > Privacy & Security > Microphone"
        case .systemAudioPermissionDenied:
            return "System audio recording permission denied. Please grant permission in System Settings > Privacy & Security"
        }
    }
}
