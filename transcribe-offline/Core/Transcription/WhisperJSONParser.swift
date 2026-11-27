//
//  WhisperJSONParser.swift
//  transcribe-offline
//
//  Parser for whisper.cpp's full JSON output (-ojf)
//  Extracts word-level timestamps, using the DTW token timestamps when present
//  (they follow the audio far more closely than the default ones)
//
//  Foundation only: this file is shared with Scripts/diarization-harness.
//

import Foundation

struct WhisperJSONParser {

    /// Minimum time a word is assumed to last after its final timestamp
    private static let wordTailSeconds = 0.3

    /// Parse whisper.cpp JSON output into timestamped words
    /// - Parameter data: Raw contents of the .json file
    /// - Returns: Parsed transcript with one entry per word
    static func parse(_ data: Data) throws -> VTTTranscript {
        // Tokens can split a multi-byte character, leaving invalid UTF-8 in token text.
        // Decode leniently: word text is taken from the (complete) segment text instead.
        let json = String(decoding: data, as: UTF8.self)

        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]] else {
            throw WhisperJSONError.invalidFormat
        }

        var words: [TimestampedWord] = []

        for segment in segments {
            guard let text = segment["text"] as? String,
                  let offsets = segment["offsets"] as? [String: Any],
                  let segmentStart = milliseconds(offsets["from"]),
                  let segmentEnd = milliseconds(offsets["to"]) else {
                continue
            }

            let segmentWords = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard !segmentWords.isEmpty else { continue }

            let timings = wordTimings(
                tokens: segment["tokens"] as? [[String: Any]] ?? [],
                fallbackStart: max(segmentStart, words.last?.end ?? 0)
            )

            if timings.count == segmentWords.count {
                for (word, timing) in zip(segmentWords, timings) {
                    words.append(TimestampedWord(text: word, start: timing.start, end: timing.end))
                }
            } else {
                // Token and text word counts disagree: spread the words evenly over the segment
                let step = (segmentEnd - segmentStart) / Double(segmentWords.count)
                for (index, word) in segmentWords.enumerated() {
                    let start = segmentStart + Double(index) * step
                    words.append(TimestampedWord(text: word, start: start, end: start + step))
                }
            }
        }

        return VTTTranscript(words: words)
    }

    // MARK: - Private Methods

    /// Start and end time of each word, built from the segment's tokens.
    /// A token starting with a space begins a new word.
    private static func wordTimings(tokens: [[String: Any]], fallbackStart: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var timings: [(start: TimeInterval, end: TimeInterval)] = []
        var current: (start: TimeInterval?, end: TimeInterval?, hasText: Bool) = (nil, nil, false)

        func closeWord() {
            guard current.hasText else { return }
            // A word made only of punctuation has no reliable time of its own: reuse the previous word's
            let start = current.start ?? timings.last?.end ?? fallbackStart
            let end = max(current.end ?? start, start) + wordTailSeconds
            timings.append((start, end))
            current = (nil, nil, false)
        }

        for token in tokens {
            guard let text = token["text"] as? String, !text.hasPrefix("[_") else { continue }

            if text.hasPrefix(" ") {
                closeWord()
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            current.hasText = true

            // Punctuation tokens drift into the following silence, so only letters and digits set the timing
            guard text.contains(where: { $0.isLetter || $0.isNumber }),
                  let time = tokenTime(token) else {
                continue
            }

            if current.start == nil {
                current.start = time
            }
            current.end = time
        }
        closeWord()

        return timings
    }

    /// Time of a token in seconds: the DTW timestamp when available, otherwise the token's start offset
    private static func tokenTime(_ token: [String: Any]) -> TimeInterval? {
        if let dtw = token["t_dtw"] as? NSNumber, dtw.doubleValue >= 0 {
            return dtw.doubleValue / 100.0  // 10 ms units
        }
        if let offsets = token["offsets"] as? [String: Any] {
            return milliseconds(offsets["from"])
        }
        return nil
    }

    private static func milliseconds(_ value: Any?) -> TimeInterval? {
        return (value as? NSNumber).map { $0.doubleValue / 1000.0 }
    }
}

enum WhisperJSONError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Whisper JSON output is not in the expected format"
        }
    }
}
