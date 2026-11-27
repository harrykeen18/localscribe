//
//  VTTParser.swift
//  transcribe-offline
//
//  Parser for WebVTT (Video Text Tracks) format
//  Used to extract word-level timestamps from whisper.cpp output
//

import Foundation

/// A word or phrase with its timestamp
struct TimestampedWord: Codable, Equatable {
    let text: String
    let start: TimeInterval  // Start time in seconds
    let end: TimeInterval    // End time in seconds
}

/// Parsed VTT transcript with timestamps
struct VTTTranscript: Codable {
    let words: [TimestampedWord]
    let fullText: String

    init(words: [TimestampedWord]) {
        self.words = words
        self.fullText = words.map { $0.text }.joined(separator: " ")
    }
}

/// Parser for WebVTT format
struct VTTParser {

    /// Parse VTT content into timestamped words
    /// - Parameter vttContent: Raw VTT file content
    /// - Returns: Parsed transcript with timestamps
    static func parse(_ vttContent: String) throws -> VTTTranscript {
        var words: [TimestampedWord] = []

        let lines = vttContent.components(separatedBy: .newlines)
        var i = 0

        // Skip header (WEBVTT)
        while i < lines.count && !lines[i].starts(with: "WEBVTT") {
            i += 1
        }
        i += 1 // Skip past WEBVTT line

        // Parse cues
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip empty lines and cue identifiers
            if line.isEmpty || line.allSatisfy({ $0.isNumber }) {
                i += 1
                continue
            }

            // Parse timestamp line (format: 00:00:01.000 --> 00:00:02.500)
            if line.contains("-->") {
                let components = line.components(separatedBy: "-->")
                guard components.count == 2 else {
                    i += 1
                    continue
                }

                let startTimeString = components[0].trimmingCharacters(in: .whitespaces)
                let endTimeString = components[1].trimmingCharacters(in: .whitespaces)

                guard let startTime = parseTime(startTimeString),
                      let endTime = parseTime(endTimeString) else {
                    i += 1
                    continue
                }

                // Next line(s) should contain the text
                i += 1
                var text = ""
                while i < lines.count && !lines[i].isEmpty && !lines[i].contains("-->") {
                    text += lines[i].trimmingCharacters(in: .whitespaces) + " "
                    i += 1
                }

                text = text.trimmingCharacters(in: .whitespaces)

                if !text.isEmpty {
                    words.append(TimestampedWord(text: text, start: startTime, end: endTime))
                }

                continue
            }

            i += 1
        }

        return VTTTranscript(words: words)
    }

    /// Parse VTT timestamp format (HH:MM:SS.mmm or MM:SS.mmm)
    /// - Parameter timeString: Timestamp string
    /// - Returns: Time in seconds
    private static func parseTime(_ timeString: String) -> TimeInterval? {
        let components = timeString.components(separatedBy: ":")

        guard components.count == 2 || components.count == 3 else {
            return nil
        }

        var hours: Double = 0
        var minutes: Double = 0
        var seconds: Double = 0

        if components.count == 3 {
            // HH:MM:SS.mmm
            guard let h = Double(components[0]),
                  let m = Double(components[1]),
                  let s = Double(components[2]) else {
                return nil
            }
            hours = h
            minutes = m
            seconds = s
        } else {
            // MM:SS.mmm
            guard let m = Double(components[0]),
                  let s = Double(components[1]) else {
                return nil
            }
            minutes = m
            seconds = s
        }

        return hours * 3600 + minutes * 60 + seconds
    }
}
