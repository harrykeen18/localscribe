import Foundation
import Combine
import AVFoundation

struct TranscriptionResult {
    let text: String
    let duration: TimeInterval
    let wordCount: Int
    let language: String?

    var isEmpty: Bool {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TranscriptionError: LocalizedError {
    case whisperExecutableNotFound
    case modelNotFound
    case audioFileNotFound
    case processError(String)
    case emptyResult
    case timeout

    var errorDescription: String? {
        switch self {
        case .whisperExecutableNotFound:
            return "Whisper executable not found in app bundle"
        case .modelNotFound:
            return "Whisper model file not found"
        case .audioFileNotFound:
            return "Audio file not found for transcription"
        case .processError(let message):
            return "Transcription failed: \(message)"
        case .emptyResult:
            return "Transcription resulted in empty text"
        case .timeout:
            return "Transcription timed out"
        }
    }
}

/// Transcription service using locally-bundled Whisper.cpp
///
/// PRIVACY: All transcription happens on-device using the Whisper.cpp engine
/// bundled with the application. Audio files never leave the device. The whisper
/// executable runs as a local process with no network access.
@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published var isTranscribing = false
    @Published var progress: Double = 0.0
    @Published var progressMessage: String = ""

    private let logger = Logger.shared
    private let fileManager = FileManager.default
    private let baseTimeoutInterval: TimeInterval = 600 // 10 minutes base timeout

    // Bundle paths
    private lazy var whisperExecutablePath: String? = {
        guard let path = Bundle.main.path(forResource: "whisper", ofType: nil) else {
            logger.error("Whisper executable not found in bundle", category: .transcription)
            return nil
        }
        logger.info("Found Whisper executable at: \(path)", category: .transcription)
        return path
    }()

    private lazy var modelPath: String? = {
        // Try multiple possible model locations
        let possiblePaths = [
            Bundle.main.path(forResource: "base.en", ofType: "bin"),
            Bundle.main.path(forResource: "models/base.en", ofType: "bin"),
        ]

        for path in possiblePaths {
            if let path = path, fileManager.fileExists(atPath: path) {
                logger.info("Found model at: \(path)", category: .transcription)
                return path
            }
        }

        logger.error("Model file not found in any expected location", category: .transcription)
        return nil
    }()

    private init() {
        logger.info("TranscriptionService initialized", category: .transcription)
        validateSetup()
    }

    private func validateSetup() {
        logger.info("Validating transcription setup...", category: .transcription)

        guard whisperExecutablePath != nil else {
            logger.error("Setup validation failed: whisper executable missing", category: .transcription)
            return
        }

        guard modelPath != nil else {
            logger.error("Setup validation failed: model file missing", category: .transcription)
            return
        }

        logger.info("✅ Transcription setup validation passed", category: .transcription)
    }

    func transcribe(audioFileURL: URL) async throws -> TranscriptionResult {
        guard !isTranscribing else {
            throw TranscriptionError.processError("Already transcribing another file")
        }

        logger.info("Starting transcription of: \(audioFileURL.lastPathComponent)", category: .transcription)

        isTranscribing = true
        progress = 0.0
        progressMessage = ""

        defer {
            isTranscribing = false
            progress = 0.0
            progressMessage = ""
        }

        do {
            let result = try await performTranscription(audioFileURL: audioFileURL)
            logger.info("Transcription completed successfully. Word count: \(result.wordCount)", category: .transcription)
            return result
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)", category: .transcription)
            throw error
        }
    }

    private func performTranscription(audioFileURL: URL) async throws -> TranscriptionResult {
        // Validate prerequisites
        guard let whisperPath = whisperExecutablePath else {
            throw TranscriptionError.whisperExecutableNotFound
        }

        guard let modelPath = modelPath else {
            throw TranscriptionError.modelNotFound
        }

        guard fileManager.fileExists(atPath: audioFileURL.path) else {
            throw TranscriptionError.audioFileNotFound
        }

        // Log file details
        let audioFileSize = (try? fileManager.attributesOfItem(atPath: audioFileURL.path)[.size] as? Int64) ?? 0
        logger.info("Audio file size: \(formatFileSize(audioFileSize))", category: .transcription)

        // Validate that the WAV file is readable and get duration
        // This catches corrupted files early with a better error message
        let audioDuration = try await validateAudioFile(audioFileURL)

        // Use chunked transcription for long recordings (>15 minutes)
        let chunkingThreshold: TimeInterval = 900 // 15 minutes
        if audioDuration > chunkingThreshold {
            logger.info("Audio duration \(String(format: "%.1f", audioDuration/60))min exceeds \(Int(chunkingThreshold/60))min threshold - using chunked transcription", category: .transcription)
            return try await performChunkedTranscription(audioFileURL: audioFileURL, whisperPath: whisperPath, modelPath: modelPath)
        } else {
            logger.info("Audio duration \(String(format: "%.1f", audioDuration/60))min - using standard transcription", category: .transcription)
            return try await performStandardTranscription(audioFileURL: audioFileURL, whisperPath: whisperPath, modelPath: modelPath, audioDuration: audioDuration)
        }
    }

    private func performStandardTranscription(audioFileURL: URL, whisperPath: String, modelPath: String, audioDuration: TimeInterval) async throws -> TranscriptionResult {

        // Calculate dynamic timeout based on audio duration
        let timeout = calculateTimeout(for: audioDuration)

        // Prepare output file
        let outputURL = audioFileURL.appendingPathExtension("txt")
        logger.info("Transcription output will be saved to: \(outputURL.path)", category: .transcription)

        // Prepare command arguments
        let arguments = [
            "-m", modelPath,
            "-f", audioFileURL.path,
            "-otxt",
            "--output-file", outputURL.deletingPathExtension().path,
            "--print-progress",
            "--language", "en"  // Force English for now
        ]

        logger.info("Whisper command: \(whisperPath) \(arguments.joined(separator: " "))", category: .transcription)

        // Run transcription process
        let startTime = Date()

        progress = 0.1

        do {
            let (output, errorOutput) = try await runWhisperProcess(
                executablePath: whisperPath,
                arguments: arguments,
                timeout: timeout,
                audioDuration: audioDuration
            )

            progress = 0.9

            let duration = Date().timeIntervalSince(startTime)
            logger.info("Whisper process completed in \(String(format: "%.2f", duration)) seconds", category: .transcription)

            if !errorOutput.isEmpty {
                logger.warning("Whisper stderr: \(errorOutput)", category: .transcription)
            }

            if !output.isEmpty {
                logger.debug("Whisper stdout: \(output)", category: .transcription)
            }

            progress = 1.0

            // Read the transcription result
            let transcriptionText = try await readTranscriptionResult(from: outputURL)

            let result = TranscriptionResult(
                text: transcriptionText,
                duration: duration,
                wordCount: countWords(in: transcriptionText),
                language: "en"
            )

            logger.info("Transcription result - Words: \(result.wordCount), Duration: \(String(format: "%.2f", result.duration))s", category: .transcription)

            if result.isEmpty {
                throw TranscriptionError.emptyResult
            }

            return result

        } catch {
            logger.error("Process execution failed: \(error)", category: .transcription)
            throw TranscriptionError.processError(error.localizedDescription)
        }
    }

    /// Transcribe long audio file by processing in chunks
    private func performChunkedTranscription(audioFileURL: URL, whisperPath: String, modelPath: String) async throws -> TranscriptionResult {
        let startTime = Date()

        // Create chunker and calculate chunks
        let chunker = AudioChunker(logger: logger)
        let chunks = try await chunker.calculateChunks(for: audioFileURL, chunkDurationSeconds: 300) // 5 minutes per chunk

        logger.info("Starting chunked transcription with \(chunks.count) chunks", category: .transcription)
        progressMessage = "Processing \(chunks.count) chunks (5 min each)"

        var allTranscripts: [String] = []
        var totalWords = 0

        // Process each chunk sequentially
        for chunk in chunks {
            let chunkNumber = chunk.index + 1
            logger.info("Processing chunk \(chunkNumber)/\(chunks.count) (\(String(format: "%.1f", chunk.startTime/60))min - \(String(format: "%.1f", (chunk.startTime + chunk.duration)/60))min)", category: .transcription)

            // Update progress and message
            progress = Double(chunk.index) / Double(chunks.count)
            progressMessage = "Chunk \(chunkNumber)/\(chunks.count) • \(String(format: "%.0f", chunk.startTime/60))-\(String(format: "%.0f", (chunk.startTime + chunk.duration)/60)) min"

            do {
                let transcript = try await transcribeChunk(
                    audioFileURL: audioFileURL,
                    chunk: chunk,
                    whisperPath: whisperPath,
                    modelPath: modelPath,
                    totalChunks: chunks.count
                )

                allTranscripts.append(transcript)
                let words = countWords(in: transcript)
                totalWords += words

                logger.info("Chunk \(chunkNumber)/\(chunks.count) completed: \(words) words", category: .transcription)

            } catch {
                logger.error("Chunk \(chunkNumber)/\(chunks.count) failed: \(error.localizedDescription)", category: .transcription)

                // Add placeholder for failed chunk to maintain continuity
                let placeholderText = "[Transcription failed for segment at \(String(format: "%.1f", chunk.startTime/60)) minutes]"
                allTranscripts.append(placeholderText)
            }
        }

        progress = 1.0
        progressMessage = "Completed \(chunks.count) chunks"

        // Stitch all transcripts together
        let fullTranscript = allTranscripts.joined(separator: " ")
        let duration = Date().timeIntervalSince(startTime)

        logger.info("✅ Chunked transcription completed: \(chunks.count) chunks processed, \(totalWords) total words, \(String(format: "%.2f", duration))s elapsed", category: .transcription)

        let result = TranscriptionResult(
            text: fullTranscript,
            duration: duration,
            wordCount: totalWords,
            language: "en"
        )

        if result.isEmpty {
            throw TranscriptionError.emptyResult
        }

        return result
    }

    /// Transcribe a single chunk of audio
    private func transcribeChunk(audioFileURL: URL, chunk: AudioChunker.Chunk, whisperPath: String, modelPath: String, totalChunks: Int) async throws -> String {
        // Prepare output file for this chunk
        let outputURL = audioFileURL.appendingPathExtension("txt")

        // Build arguments with offset and duration
        let arguments = [
            "-m", modelPath,
            "-f", audioFileURL.path,
            "-ot", "\(chunk.startOffset)",  // Start offset in milliseconds
            "-d", "\(chunk.durationMs)",    // Duration in milliseconds
            "-otxt",
            "--output-file", outputURL.deletingPathExtension().path,
            "--print-progress",
            "--language", "en"
        ]

        // Timeout: 10 minutes per 5-minute chunk (2x ratio)
        let chunkTimeout: TimeInterval = 600

        logger.debug("Chunk \(chunk.index + 1) command: \(whisperPath) \(arguments.joined(separator: " "))", category: .transcription)

        // Run transcription for this chunk
        let (_, stderr) = try await runWhisperProcess(
            executablePath: whisperPath,
            arguments: arguments,
            timeout: chunkTimeout,
            audioDuration: chunk.duration,
            chunkInfo: (current: chunk.index + 1, total: totalChunks)
        )

        if !stderr.isEmpty {
            logger.debug("Chunk \(chunk.index + 1) stderr: \(stderr)", category: .transcription)
        }

        // Read the transcription result
        let transcriptionText = try await readTranscriptionResult(from: outputURL)

        return transcriptionText
    }

    private nonisolated func runWhisperProcess(executablePath: String, arguments: [String], timeout: TimeInterval, audioDuration: TimeInterval, chunkInfo: (current: Int, total: Int)? = nil) async throws -> (String, String) {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Buffers for collecting output (thread-safe)
            final class OutputBuffers: @unchecked Sendable {
                var errorBuffer = ""
                var stderrLines: [String] = []
            }
            let buffers = OutputBuffers()

            // Track timeout state
            final class ProcessState: @unchecked Sendable {
                var timer: Timer?
                var timedOut = false
                var hasResumed = false
            }
            let state = ProcessState()

            // Set up timeout with dynamic duration
            state.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                if process.isRunning {
                    state.timedOut = true
                    process.terminate()
                }
            }

            // Read stderr in real-time to parse progress
            let stderrHandle = errorPipe.fileHandleForReading
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.count > 0, let text = String(data: data, encoding: .utf8) {
                    buffers.errorBuffer += text
                    let lines = buffers.errorBuffer.components(separatedBy: .newlines)

                    // Process complete lines (keep last partial line in buffer)
                    for i in 0..<(lines.count - 1) {
                        let line = lines[i]
                        buffers.stderrLines.append(line)

                        // Parse progress from Whisper's stderr
                        // Example: "whisper_print_progress_callback: progress =   76%"
                        // Use flexible regex to handle varying whitespace
                        if line.range(of: #"progress\s*=\s*\d+%"#, options: .regularExpression) != nil {
                            if let percentRange = line.range(of: #"\d+%"#, options: .regularExpression) {
                                let percentString = line[percentRange].dropLast() // Remove '%'
                                if let percent = Int(percentString) {
                                    Task { @MainActor in
                                        self.progress = Double(percent) / 100.0
                                        self.logger.debug("Transcription progress: \(percent)%", category: .transcription)
                                    }
                                }
                            }
                        }
                    }

                    // Keep last incomplete line
                    buffers.errorBuffer = lines.last ?? ""
                }
            }

            process.terminationHandler = { process in
                // Stop reading stderr
                stderrHandle.readabilityHandler = nil

                // Read any remaining data
                let remainingStderr = stderrHandle.readDataToEndOfFile()
                if let text = String(data: remainingStderr, encoding: .utf8) {
                    buffers.stderrLines.append(contentsOf: text.components(separatedBy: .newlines))
                }

                state.timer?.invalidate()
                state.timer = nil

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                // Join all stderr lines
                let fullStderr = buffers.stderrLines.joined(separator: "\n")

                guard !state.hasResumed else { return }
                state.hasResumed = true

                if state.timedOut {
                    // Timeout occurred
                    let timeoutMessage = "Transcription timed out after \(String(format: "%.0f", timeout/60)) minutes for a \(String(format: "%.1f", audioDuration/60)) minute recording. This can happen with very long recordings. Try recording in shorter sessions."
                    continuation.resume(throwing: TranscriptionError.processError(timeoutMessage))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: (output, fullStderr))
                } else {
                    // Filter stderr to remove diagnostic spam
                    let errorMessage = self.filterStderrErrors(fullStderr)
                    continuation.resume(throwing: TranscriptionError.processError(errorMessage))
                }
            }

            do {
                try process.run()
                Task { @MainActor in
                    logger.info("Whisper process started with PID: \(process.processIdentifier)", category: .transcription)
                }
            } catch {
                state.timer?.invalidate()
                state.timer = nil
                stderrHandle.readabilityHandler = nil
                guard !state.hasResumed else { return }
                state.hasResumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    // Filter stderr to show only actual errors, not diagnostic logs
    private nonisolated func filterStderrErrors(_ stderr: String) -> String {
        let lines = stderr.components(separatedBy: .newlines)

        // Look for lines that indicate actual errors
        let errorKeywords = ["error", "failed", "exception", "fatal", "critical"]
        let errorLines = lines.filter { line in
            let lowercased = line.lowercased()
            return errorKeywords.contains(where: { lowercased.contains($0) })
        }

        if !errorLines.isEmpty {
            return errorLines.joined(separator: "\n")
        }

        // No specific errors found, return generic message
        return "Transcription process failed. Check that Whisper model and audio file are valid."
    }

    private func readTranscriptionResult(from outputURL: URL) async throws -> String {
        logger.info("Reading transcription result from: \(outputURL.path)", category: .transcription)

        // Give the file system a moment to flush
        try await Task.sleep(for: .milliseconds(100))

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.processError("Transcription output file not created")
        }

        let transcriptionData = try Data(contentsOf: outputURL)
        let transcriptionText = String(data: transcriptionData, encoding: .utf8) ?? ""

        let cleanText = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Read \(transcriptionData.count) bytes, \(cleanText.count) characters of transcription text", category: .transcription)

        // Clean up the temporary transcription file
        try? fileManager.removeItem(at: outputURL)
        logger.debug("Cleaned up temporary transcription file", category: .transcription)

        return cleanText
    }

    // MARK: - Utility methods

    private func calculateTimeout(for audioDuration: TimeInterval) -> TimeInterval {
        // Calculate timeout: max(base timeout, audio duration * 2)
        // This gives plenty of buffer for long recordings
        // Example: 30-min audio = 60-min timeout
        let dynamicTimeout = max(baseTimeoutInterval, audioDuration * 2)
        logger.info("Calculated timeout: \(String(format: "%.0f", dynamicTimeout))s for \(String(format: "%.0f", audioDuration))s audio", category: .transcription)
        return dynamicTimeout
    }

    private func countWords(in text: String) -> Int {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        return words.filter { !$0.isEmpty }.count
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Public utility methods

    func isSetupValid() -> Bool {
        return whisperExecutablePath != nil && modelPath != nil
    }

    func getSetupStatus() -> String {
        var status: [String] = []

        if whisperExecutablePath != nil {
            status.append("✅ Whisper executable found")
        } else {
            status.append("❌ Whisper executable missing")
        }

        if modelPath != nil {
            status.append("✅ Model file found")
        } else {
            status.append("❌ Model file missing")
        }

        return status.joined(separator: "\n")
    }

    // MARK: - Validation

    private func validateAudioFile(_ audioFileURL: URL) async throws -> TimeInterval {
        logger.info("Validating audio file: \(audioFileURL.lastPathComponent)", category: .transcription)

        do {
            // Try to open the audio file with AVAudioFile
            // This will catch corrupted WAV files before passing to whisper
            let audioFile = try AVAudioFile(forReading: audioFileURL)

            let format = audioFile.processingFormat
            let frameCount = audioFile.length
            let duration = Double(frameCount) / format.sampleRate

            logger.info("✅ Audio file validated: \(format.sampleRate)Hz, \(format.channelCount)ch, \(String(format: "%.1f", duration))s, \(frameCount) frames", category: .transcription)

            return duration

        } catch {
            logger.error("❌ Audio file validation failed: \(error.localizedDescription)", category: .transcription)
            throw TranscriptionError.processError("Audio file is corrupted or unreadable. This can happen with very long recordings. Please try recording again with a shorter duration.")
        }
    }
}