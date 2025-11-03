import Foundation
import ScreenCaptureKit
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

/// ScreenCaptureKitRecorder captures both system audio and microphone using ScreenCaptureKit API (macOS 15+)
///
/// PRIVACY: This recorder uses ScreenCaptureKit to capture audio streams locally. All audio
/// processing happens on-device - no data is transmitted over the network. Audio files are
/// written to temporary storage and immediately deleted after transcription (see AudioRecorder).
/// This allows capturing microphone even when Google Meet or other apps are using it.
class ScreenCaptureKitRecorder: NSObject {
    private let logger = Logger.shared

    // ScreenCaptureKit objects
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?

    // Separate audio files for each stream
    nonisolated(unsafe) private var systemAudioFile: AVAudioFile?
    nonisolated(unsafe) private var microphoneAudioFile: AVAudioFile?
    nonisolated(unsafe) private var outputFormat: AVAudioFormat?
    private let systemFileQueue = DispatchQueue(label: "com.transcribe.screencapturekit.system", qos: .userInitiated)
    private let micFileQueue = DispatchQueue(label: "com.transcribe.screencapturekit.mic", qos: .userInitiated)

    // Note: We don't cache converters - they're created on-demand for each buffer
    // This avoids all threading issues and is performant enough for audio processing

    // Configuration
    private let sampleRate: Double
    private let systemOutputURL: URL
    private let microphoneOutputURL: URL

    // State
    nonisolated(unsafe) private var isRecording = false

    // Buffer counters for logging
    nonisolated(unsafe) private static var systemAudioBufferCount: Int = 0
    nonisolated(unsafe) private static var microphoneBufferCount: Int = 0
    nonisolated(unsafe) private static var loggedNonPCMFormat = false
    nonisolated(unsafe) private static var loggedMicData = false

    // Constants
    private static let bufferLoggingInterval = 500  // Log every N buffers to avoid spam
    private static let minVideoWidth = 2  // Minimal video dimensions (unused but required)
    private static let minVideoHeight = 2
    private static let minVideoFrameRate = 1  // 1 FPS (minimal overhead)

    @MainActor
    init(sampleRate: Double = 16000, systemOutputURL: URL, microphoneOutputURL: URL) {
        self.sampleRate = sampleRate
        self.systemOutputURL = systemOutputURL
        self.microphoneOutputURL = microphoneOutputURL
        super.init()

        logger.info("ScreenCaptureKitRecorder initialized with \(sampleRate)Hz", category: .audio)
        logger.info("System audio will be saved to: \(systemOutputURL.lastPathComponent)", category: .audio)
        logger.info("Microphone will be saved to: \(microphoneOutputURL.lastPathComponent)", category: .audio)
    }

    // MARK: - Public API

    @MainActor
    func startRecording() async throws {
        guard !isRecording else {
            logger.warning("Already recording", category: .audio)
            return
        }

        logger.info("Starting ScreenCaptureKit recording (dual stream)", category: .audio)

        // Record at 16kHz Float32 for processing (Whisper resamples to 16kHz anyway)
        // Files will be written as Int16 for 50% size reduction vs Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,  // Optimal sample rate for speech transcription
            channels: 1,
            interleaved: false
        ) else {
            logger.error("Failed to create target audio format", category: .audio)
            throw ScreenCaptureKitError.failedToCreateFormat
        }

        self.outputFormat = targetFormat
        logger.info("Recording format: 16000Hz, 1ch, Float32 (processing), Int16 (file)", category: .audio)

        // Create separate audio files for system and microphone at 16kHz Int16
        logger.info("Creating system audio file at: \(systemOutputURL.path)", category: .file)
        logger.info("Creating microphone file at: \(microphoneOutputURL.path)", category: .file)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: true
            ]
            systemAudioFile = try AVAudioFile(forWriting: systemOutputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            microphoneAudioFile = try AVAudioFile(forWriting: microphoneOutputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            logger.info("Audio files created successfully", category: .file)
        } catch {
            logger.error("Failed to create audio files: \(error.localizedDescription)", category: .file)
            throw error
        }

        // Get shareable content (displays)
        logger.info("Getting shareable content...", category: .audio)
        let content = try await SCShareableContent.current

        // We need at least one display to create a stream
        guard let display = content.displays.first else {
            throw ScreenCaptureKitError.noDisplaysAvailable
        }

        logger.info("Found display: \(display.displayID)", category: .audio)

        // Create content filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream for audio-only capture
        let streamConfig = SCStreamConfiguration()

        // Enable both system audio and microphone capture
        streamConfig.capturesAudio = true  // System audio
        streamConfig.captureMicrophone = true
        streamConfig.microphoneCaptureDeviceID = nil // Use default microphone
        streamConfig.sampleRate = 16000 // Sample rate for both streams (optimal for speech)
        streamConfig.channelCount = 1 // Mono (we downmix to mono anyway)

        // Minimize video overhead (we don't use video, but ScreenCaptureKit still generates frames)
        // Note: "stream output NOT found" errors in console are harmless - they occur because
        // we're not adding a .screen output handler, but we need the display filter to create the stream
        streamConfig.width = Self.minVideoWidth
        streamConfig.height = Self.minVideoHeight
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.minVideoFrameRate))

        logger.info("Stream configuration: audio=true (mono), mic=true, sampleRate=16000Hz, video=2x2@1fps (ignored)", category: .audio)

        // Create stream output handler
        let output = AudioStreamOutput(recorder: self)
        self.streamOutput = output

        // Create and start stream
        logger.info("Creating SCStream...", category: .audio)
        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        self.stream = newStream

        // Add stream outputs - use same queue for both to avoid threading issues
        let sampleQueue = DispatchQueue(label: "com.transcribe.screencapturekit.samples", qos: .userInitiated)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        try newStream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: sampleQueue)
        logger.info("Added stream outputs for audio and microphone (audio-only mode)", category: .audio)

        // IMPORTANT: Set isRecording = true BEFORE startCapture()
        // because startCapture() starts delivering buffers immediately in the background
        // even though it doesn't return until later (async)
        isRecording = true
        logger.info("Set isRecording = true (before startCapture)", category: .audio)

        logger.info("Starting stream...", category: .audio)
        do {
            try await newStream.startCapture()
            logger.info("Stream.startCapture() returned successfully", category: .audio)
            logger.info("✅ ScreenCaptureKit recording started", category: .audio)
            logger.info("Waiting for audio buffers to arrive...", category: .audio)
        } catch {
            isRecording = false
            logger.error("Failed to start stream capture: \(error.localizedDescription)", category: .audio)
            throw error
        }
    }

    @MainActor
    func stopRecording() async throws {
        guard isRecording else {
            logger.warning("Not currently recording", category: .audio)
            return
        }

        logger.info("Stopping ScreenCaptureKit recording...", category: .audio)

        // Stop the stream
        if let stream = stream {
            try await stream.stopCapture()
            self.stream = nil
            logger.debug("Stream stopped", category: .audio)
        }

        // Close audio files
        systemAudioFile = nil
        microphoneAudioFile = nil
        outputFormat = nil
        streamOutput = nil

        isRecording = false
        logger.info("✅ ScreenCaptureKit recording stopped", category: .audio)
    }

    // MARK: - Audio Processing

    nonisolated func processSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Capture all shared state at method entry to avoid TOCTOU races
        guard isRecording else { return }
        guard let format = outputFormat,
              let audioFile = systemAudioFile else { return }
        let queue = systemFileQueue

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = convertToAVAudioPCMBuffer(sampleBuffer: sampleBuffer) else {
            return
        }

        // Resample to target format and write to system audio file
        writeAudioBuffer(pcmBuffer, sourceType: "system", targetFormat: format, audioFile: audioFile, fileQueue: queue)
    }

    nonisolated func processMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Capture all shared state at method entry to avoid TOCTOU races
        guard isRecording else { return }
        guard let format = outputFormat,
              let audioFile = microphoneAudioFile else { return }
        let queue = micFileQueue

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = convertToAVAudioPCMBuffer(sampleBuffer: sampleBuffer) else {
            return
        }

        // Resample to target format and write to microphone file
        writeAudioBuffer(pcmBuffer, sourceType: "mic", targetFormat: format, audioFile: audioFile, fileQueue: queue)
    }

    // MARK: - Private Methods

    private nonisolated func convertToAVAudioPCMBuffer(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Get format description
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else {
            return nil
        }

        // Check if the format is valid - Google Meet causes AVAudioFormat to return invalid/zero values
        // When AVAudioFormat is invalid (all zeros), we need to extract raw PCM data directly
        if audioFormat.commonFormat == .otherFormat || audioFormat.sampleRate == 0 {
            // Invalid AVAudioFormat - this happens when Google Meet has exclusive mic access
            // The audio data IS there, but the format description is malformed
            // Solution: Extract raw PCM and create buffer with our expected format (48kHz mono)

            if !Self.loggedNonPCMFormat {
                Self.loggedNonPCMFormat = true
                Task { @MainActor in
                    Logger.shared.warning("⚠️ Received invalid AVAudioFormat from ScreenCaptureKit (Google Meet active)", category: .audio)
                    Logger.shared.warning("Attempting to extract raw PCM data directly...", category: .audio)
                }
            }

            // Assume ScreenCaptureKit delivers 16kHz mono Float32 for microphone
            guard let expectedFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ) else {
                return nil
            }

            // Create buffer with expected format
            guard let validBuffer = AVAudioPCMBuffer(pcmFormat: expectedFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
                return nil
            }
            validBuffer.frameLength = AVAudioFrameCount(numSamples)

            // Extract raw audio data directly from CMSampleBuffer
            var blockBuffer: CMBlockBuffer?
            var bufferListSizeNeededOut: Int = 0

            var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &bufferListSizeNeededOut,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else {
                return nil
            }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer {
                bufferListPointer.deallocate()
            }

            status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: bufferListPointer,
                bufferListSize: bufferListSizeNeededOut,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else {
                return nil
            }

            let audioBufferListPointer = UnsafeMutableAudioBufferListPointer(bufferListPointer)

            // Copy raw float data to our buffer
            guard let channelData = validBuffer.floatChannelData,
                  let firstBuffer = audioBufferListPointer.first,
                  let sourceData = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                return nil
            }

            // Detect actual format from byte size
            // If byteSize / numSamples = 4, it's Float32 mono
            // If byteSize / numSamples = 2, it's Int16 mono
            // If byteSize / numSamples = 12, it's likely Int16 stereo interleaved (2 channels × 2 bytes × 3?)
            let bytesPerFrame = Int(firstBuffer.mDataByteSize) / Int(numSamples)

            // Log once per session
            let shouldLog = !Self.loggedMicData
            if shouldLog {
                Self.loggedMicData = true
                Task { @MainActor in
                    Logger.shared.warning("📊 Microphone buffer: \(numSamples) frames, \(firstBuffer.mDataByteSize) bytes, \(bytesPerFrame) bytes/frame", category: .audio)
                }
            }

            // Handle different formats
            if bytesPerFrame == 2 {
                // Int16 mono - convert to Float32
                let int16Data = sourceData.withMemoryRebound(to: Int16.self, capacity: Int(numSamples)) { $0 }
                for i in 0..<Int(numSamples) {
                    channelData[0][i] = Float(int16Data[i]) / 32768.0
                }
            } else if bytesPerFrame == 4 {
                // Float32 mono - direct copy
                channelData[0].update(from: sourceData, count: Int(numSamples))
            } else if bytesPerFrame == 12 {
                // 12 bytes/frame could be:
                // - Float32 × 3 channels (4 × 3 = 12)
                // - Int16 × 6 channels (2 × 6 = 12)

                // Try Float32 3-channel (most likely)
                // Assume channels are: [L, R, Center] or [L, R, Surround]
                // We'll average all 3 channels
                let float32Data = sourceData
                for i in 0..<Int(numSamples) {
                    let ch0 = float32Data[i * 3]
                    let ch1 = float32Data[i * 3 + 1]
                    let ch2 = float32Data[i * 3 + 2]
                    channelData[0][i] = (ch0 + ch1 + ch2) / 3.0
                }

                // Log first few samples to see if we're getting audio
                if shouldLog {
                    let sample0 = channelData[0][0]
                    let sample1 = channelData[0][1]
                    let sample2 = channelData[0][2]
                    Task { @MainActor in
                        Logger.shared.warning("📊 First samples after 3-ch→mono: [\(sample0), \(sample1), \(sample2)]", category: .audio)
                    }
                }
            } else {
                // Unknown format - try Float32 anyway
                let frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.stride
                let framesToCopy = min(frameCount, Int(numSamples))
                channelData[0].update(from: sourceData, count: framesToCopy)
            }

            return validBuffer
        }

        // AVAudioPCMBuffer requires a "standard" format
        let bufferFormat: AVAudioFormat
        if audioFormat.isStandard {
            bufferFormat = audioFormat
        } else {
            // Not standard but still PCM - create compatible format
            guard let compatibleFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audioFormat.sampleRate,
                channels: audioFormat.channelCount,
                interleaved: audioFormat.isInterleaved
            ) else {
                return nil
            }
            bufferFormat = compatibleFormat
        }

        // Create PCM buffer - this will only work with PCM formats
        guard let validBuffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }

        validBuffer.frameLength = AVAudioFrameCount(numSamples)

        // Get the audio buffer list
        var blockBuffer: CMBlockBuffer?
        var bufferListSizeNeededOut: Int = 0

        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeededOut,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer {
            bufferListPointer.deallocate()
        }

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: bufferListSizeNeededOut,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        let audioBufferListPointer = UnsafeMutableAudioBufferListPointer(bufferListPointer)

        if bufferFormat.isInterleaved {
            guard let firstBuffer = audioBufferListPointer.first,
                  let sourceData = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                return nil
            }

            let ablPointer = validBuffer.mutableAudioBufferList
            let abl = UnsafeMutableAudioBufferListPointer(ablPointer)

            guard let destBuffer = abl.first,
                  let destData = destBuffer.mData else {
                return nil
            }

            let byteCount = Int(firstBuffer.mDataByteSize)
            destData.copyMemory(from: sourceData, byteCount: byteCount)

        } else {
            guard let channelData = validBuffer.floatChannelData else {
                return nil
            }

            for (channelIndex, audioBuffer) in audioBufferListPointer.enumerated() {
                guard channelIndex < Int(bufferFormat.channelCount),
                      let sourceData = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }

                let frameCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride
                let framesToCopy = min(frameCount, Int(numSamples))

                channelData[channelIndex].update(from: sourceData, count: framesToCopy)
            }
        }

        return validBuffer
    }

    private nonisolated func writeAudioBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        sourceType: String,
        targetFormat: AVAudioFormat,
        audioFile: AVAudioFile?,
        fileQueue: DispatchQueue
    ) {
        // ScreenCaptureKit delivers audio at 48kHz, but we want 16kHz files
        // Need to resample + downmix to mono before writing

        let inputFormat = inputBuffer.format
        let inputSampleRate = inputFormat.sampleRate
        let targetSampleRate = targetFormat.sampleRate

        // Check if we need to resample
        let needsResampling = inputSampleRate != targetSampleRate

        // Step 1: Handle channel count (stereo → mono if needed)
        let monoBuffer: AVAudioPCMBuffer
        if inputFormat.channelCount == 2 {
            // Need to downmix stereo to mono first (at original sample rate)
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputSampleRate,
                channels: 1,
                interleaved: false
            ),
            let tempBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: inputBuffer.frameLength) else {
                return
            }

            tempBuffer.frameLength = inputBuffer.frameLength

            guard let inputChannelData = inputBuffer.floatChannelData,
                  let outputChannelData = tempBuffer.floatChannelData else {
                return
            }

            let left = inputChannelData[0]
            let right = inputChannelData[1]
            let mono = outputChannelData[0]

            for i in 0..<Int(inputBuffer.frameLength) {
                mono[i] = (left[i] + right[i]) * 0.5
            }

            monoBuffer = tempBuffer
        } else {
            // Already mono
            monoBuffer = inputBuffer
        }

        // Step 2: Resample if needed (e.g., 48kHz → 16kHz)
        let finalBuffer: AVAudioPCMBuffer
        if needsResampling {
            // Calculate output frame count after resampling
            let outputFrameCount = AVAudioFrameCount(Double(monoBuffer.frameLength) * targetSampleRate / inputSampleRate)

            guard let resampledBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
                return
            }

            // Create converter
            guard let converter = AVAudioConverter(from: monoBuffer.format, to: targetFormat) else {
                return
            }

            // Perform conversion
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return monoBuffer
            }

            let status = converter.convert(to: resampledBuffer, error: &error, withInputFrom: inputBlock)

            if status == .error || error != nil {
                return
            }

            finalBuffer = resampledBuffer
        } else {
            // No resampling needed, but might need to create buffer in target format
            if monoBuffer.format.sampleRate == targetFormat.sampleRate {
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: monoBuffer.frameLength) else {
                    return
                }
                outputBuffer.frameLength = monoBuffer.frameLength

                // Copy data
                if let srcData = monoBuffer.floatChannelData,
                   let dstData = outputBuffer.floatChannelData {
                    dstData[0].update(from: srcData[0], count: Int(monoBuffer.frameLength))
                }

                finalBuffer = outputBuffer
            } else {
                finalBuffer = monoBuffer
            }
        }

        // Make a copy for async write
        guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: finalBuffer.frameCapacity) else {
            return
        }
        bufferCopy.frameLength = finalBuffer.frameLength

        if let srcData = finalBuffer.floatChannelData,
           let dstData = bufferCopy.floatChannelData {
            dstData[0].update(from: srcData[0], count: Int(finalBuffer.frameLength))
        }

        // Write to file on serial queue for thread safety
        fileQueue.async { [bufferCopy] in
            guard let audioFile = audioFile else { return }

            do {
                try audioFile.write(from: bufferCopy)
            } catch {
                // Silently fail
            }
        }
    }
}

// MARK: - Stream Output Handler

private class AudioStreamOutput: NSObject, SCStreamOutput {
    weak var recorder: ScreenCaptureKitRecorder?

    init(recorder: ScreenCaptureKitRecorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard let recorder = recorder else {
            return
        }

        // Wrap in autoreleasepool to prevent memory buildup
        autoreleasepool {
            switch outputType {
            case .audio:
                recorder.processSystemAudioBuffer(sampleBuffer)
            case .microphone:
                recorder.processMicrophoneBuffer(sampleBuffer)
            case .screen:
                // Ignore video frames - we only want audio
                break
            default:
                break
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            Logger.shared.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription)", category: .audio)
        }
    }
}

// MARK: - Errors

enum ScreenCaptureKitError: LocalizedError {
    case failedToCreateFormat
    case noDisplaysAvailable
    case failedToCreateStream

    var errorDescription: String? {
        switch self {
        case .failedToCreateFormat:
            return "Failed to create audio format"
        case .noDisplaysAvailable:
            return "No displays available for screen capture"
        case .failedToCreateStream:
            return "Failed to create ScreenCaptureKit stream"
        }
    }
}
