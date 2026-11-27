//
//  DiarizationService.swift
//  transcribe-offline
//
//  Speaker diarization service using FluidAudio
//  Identifies different speakers in audio recordings
//

import Foundation
import FluidAudio

/// The separate tracks of a recording, when both were captured
nonisolated struct RecordingTracks: Codable, Equatable, Sendable {
    let microphoneURL: URL
    let systemURL: URL
}

/// Service for identifying speakers in audio files
class DiarizationService {

    // MARK: - Singleton

    static let shared = DiarizationService()

    // MARK: - Properties

    private let logger = Logger.shared
    private var loadTask: Task<SortformerSpeakerDiarizer, Error>?

    private nonisolated static let sampleRate = 16_000

    // MARK: - Initialization

    private init() {
        logger.info("DiarizationService initialized", category: .audio)
    }

    // MARK: - Public Methods

    /// Load the bundled diarization model (offline, no network)
    func prepareModels() async throws {
        _ = try await loadDiarizer()
    }

    /// Start loading the model in the background so the first recording doesn't wait for it
    func warmUp() {
        Task {
            do {
                try await prepareModels()
            } catch {
                logger.warning("Diarization model warm-up failed: \(error.localizedDescription)", category: .audio)
            }
        }
    }

    /// Diarize an audio file to identify speakers
    /// - Parameters:
    ///   - audioFileURL: Path to the (mixed) audio file
    ///   - tracks: The separate microphone and system tracks, used to tell local from remote speakers
    /// - Returns: Array of speaker segments with timestamps
    func diarize(audioFileURL: URL, tracks: RecordingTracks? = nil) async throws -> [SpeakerSegment] {
        let diarizer = try await loadDiarizer()

        logger.info("Starting diarization for: \(audioFileURL.lastPathComponent)", category: .audio)
        let startTime = Date()

        do {
            // Audio processing is slow, so it runs off the main actor
            let outcome = try await Task.detached(priority: .userInitiated) {
                try Self.process(audioFileURL: audioFileURL, tracks: tracks, diarizer: diarizer)
            }.value

            let duration = Date().timeIntervalSince(startTime)
            let rtf = duration / outcome.audioDuration

            logger.info(outcome.trackNote, category: .audio)
            logger.info("✅ Diarization completed in \(String(format: "%.2f", duration))s (RTF: \(String(format: "%.2f", rtf)))", category: .audio)
            logger.info("Detected \(Set(outcome.segments.map { $0.speaker }).count) speakers in \(outcome.segments.count) segments", category: .audio)

            return outcome.segments

        } catch {
            logger.error("Diarization failed: \(error.localizedDescription)", category: .audio)
            throw DiarizationError.processingFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    /// Load the model once and share it between callers. The first load after install can take
    /// a couple of minutes while Core ML prepares the model for this Mac.
    private func loadDiarizer() async throws -> SortformerSpeakerDiarizer {
        if loadTask == nil {
            logger.info("Loading diarization model...", category: .audio)
            let startTime = Date()

            guard let modelURL = Bundle.main.url(forResource: SortformerSpeakerDiarizer.modelName, withExtension: "mlmodelc") else {
                throw DiarizationError.modelNotFound("\(SortformerSpeakerDiarizer.modelName).mlmodelc")
            }

            loadTask = Task.detached(priority: .userInitiated) {
                try SortformerSpeakerDiarizer(modelURL: modelURL)
            }

            do {
                let diarizer = try await loadTask!.value
                logger.info("✅ Diarization model loaded in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s", category: .audio)
                return diarizer
            } catch {
                loadTask = nil
                throw error
            }
        }

        return try await loadTask!.value
    }

    private struct Outcome: Sendable {
        let segments: [SpeakerSegment]
        let audioDuration: TimeInterval
        let trackNote: String
    }

    /// Voice diarization of the mixed audio, then correction using the separate tracks when available
    private nonisolated static func process(audioFileURL: URL, tracks: RecordingTracks?, diarizer: SortformerSpeakerDiarizer) throws -> Outcome {
        let converter = AudioConverter(sampleRate: Double(sampleRate))
        let samples = try converter.resampleAudioFile(path: audioFileURL.path)
        let audioDuration = Double(samples.count) / Double(sampleRate)

        // Identify speakers by voice
        let voiceSegments = try diarizer.diarize(samples: samples, sampleRate: Double(sampleRate))

        func voiceOnly(_ note: String) -> Outcome {
            Outcome(segments: TrackSpeakerRefiner.renumber(segments: voiceSegments), audioDuration: audioDuration, trackNote: note)
        }

        let fileManager = FileManager.default
        guard let tracks = tracks,
              fileManager.fileExists(atPath: tracks.microphoneURL.path),
              fileManager.fileExists(atPath: tracks.systemURL.path) else {
            return voiceOnly("No separate tracks available - using voice diarization only")
        }

        do {
            let microphone = try converter.resampleAudioFile(path: tracks.microphoneURL.path)
            let system = try converter.resampleAudioFile(path: tracks.systemURL.path)

            let result = TrackSpeakerRefiner.refine(
                segments: voiceSegments,
                microphone: microphone,
                system: system,
                sampleRate: sampleRate
            )

            let note = result.usedTracks
                ? "Refined speakers using microphone/system tracks (local speaker named: \(result.namedLocalSpeaker))"
                : "System track has too little audio to separate speakers - using voice diarization only"

            return Outcome(segments: result.segments, audioDuration: audioDuration, trackNote: note)

        } catch {
            return voiceOnly("Could not read separate tracks: \(error.localizedDescription) - using voice diarization only")
        }
    }
}

// MARK: - Errors

enum DiarizationError: LocalizedError {
    case notInitialized
    case bundleNotFound
    case modelNotFound(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Diarization service not initialized. Call prepareModels() first."
        case .bundleNotFound:
            return "App bundle not found"
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .processingFailed(let reason):
            return "Diarization processing failed: \(reason)"
        }
    }
}
