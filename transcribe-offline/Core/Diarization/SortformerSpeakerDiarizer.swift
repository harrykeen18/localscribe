//
//  SortformerSpeakerDiarizer.swift
//  transcribe-offline
//
//  Voice diarization using FluidAudio's Sortformer model (up to 4 speakers).
//  The model is loaded from a local compiled Core ML bundle - nothing is downloaded.
//
//  FluidAudio and Core ML only: this file is shared with Scripts/diarization-harness.
//

import CoreML
import Foundation
import FluidAudio

/// Not tied to the main actor so recordings can be processed in the background.
/// Use one instance from one task at a time.
nonisolated final class SortformerSpeakerDiarizer: @unchecked Sendable {

    /// File name (without extension) of the bundled compiled model
    static let modelName = "SortformerNvidiaHigh_v2.1"

    /// High-context configuration: slowest to produce output, most accurate for complete recordings
    private let config = SortformerConfig.highContextV2_1

    private let models: SortformerModels

    /// Silence appended to every recording (longer than one model chunk)
    private let trailingSilenceSeconds = 35.0

    /// Load the compiled model (.mlmodelc) from disk
    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = SortformerModels.recommendedComputeUnits(for: config)

        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.models = try SortformerModels(config: config, main: model)
    }

    /// Identify speakers in a complete recording
    /// - Parameters:
    ///   - samples: Mono audio samples
    ///   - sampleRate: Sample rate of the samples
    /// - Returns: Speaker segments with raw speaker IDs ("1", "2", ...), sorted by start time
    func diarize(samples: [Float], sampleRate: Double) throws -> [SpeakerSegment] {
        // A fresh diarizer per recording so speakers never carry over between recordings
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)

        // The model works in ~30 s chunks and only reports a chunk once it is complete, so the
        // recording is followed by silence to make sure its final seconds are covered
        let audioDuration = Double(samples.count) / sampleRate
        let padding = [Float](repeating: 0, count: Int(trailingSilenceSeconds * sampleRate))

        let timeline = try diarizer.processComplete(samples + padding, sourceSampleRate: sampleRate)

        return timeline.speakers
            .flatMap { index, speaker in
                speaker.finalizedSegments.compactMap { segment -> SpeakerSegment? in
                    let start = TimeInterval(segment.startTime)
                    let end = min(TimeInterval(segment.endTime), audioDuration)
                    guard start < end else { return nil }
                    return SpeakerSegment(speaker: "\(index + 1)", start: start, end: end)
                }
            }
            .sorted { $0.start < $1.start }
    }
}
