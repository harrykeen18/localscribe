//
//  AudioChunker.swift
//  transcribe-offline
//
//  Created for chunked transcription of long audio files
//

import AVFoundation
import Foundation

/// Splits long audio files into manageable chunks for transcription
class AudioChunker {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Represents a chunk of audio to be transcribed
    struct Chunk {
        let index: Int              // 0-based chunk index
        let startTime: TimeInterval // Start time in seconds
        let duration: TimeInterval  // Duration in seconds
        let startOffset: Int        // Start offset in milliseconds (for Whisper -ot flag)
        let durationMs: Int         // Duration in milliseconds (for Whisper -d flag)
    }

    /// Calculates chunks for a given audio file
    /// - Parameters:
    ///   - audioURL: URL of the audio file to chunk
    ///   - chunkDurationSeconds: Desired chunk duration (default: 300 seconds = 5 minutes)
    /// - Returns: Array of chunks covering the entire audio file
    func calculateChunks(for audioURL: URL, chunkDurationSeconds: TimeInterval = 300) async throws -> [Chunk] {
        // Get audio duration using AVURLAsset (modern API)
        let asset = AVURLAsset(url: audioURL)
        let audioDuration = try await asset.load(.duration).seconds

        guard audioDuration > 0 else {
            throw AudioChunkerError.invalidDuration
        }

        logger.info(
            "Calculating chunks for \(String(format: "%.1f", audioDuration))s audio with \(String(format: "%.0f", chunkDurationSeconds))s chunks",
            category: .transcription
        )

        var chunks: [Chunk] = []
        var currentTime: TimeInterval = 0
        var index = 0

        // Create chunks until we've covered the entire audio
        while currentTime < audioDuration {
            let remainingTime = audioDuration - currentTime
            let chunkDuration = min(chunkDurationSeconds, remainingTime)

            chunks.append(Chunk(
                index: index,
                startTime: currentTime,
                duration: chunkDuration,
                startOffset: Int(currentTime * 1000),  // Convert to milliseconds
                durationMs: Int(chunkDuration * 1000)
            ))

            currentTime += chunkDuration
            index += 1
        }

        logger.info("Created \(chunks.count) chunks covering \(String(format: "%.1f", audioDuration))s of audio", category: .transcription)
        return chunks
    }
}

/// Errors that can occur during audio chunking
enum AudioChunkerError: LocalizedError {
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "Audio file has invalid or zero duration"
        }
    }
}
