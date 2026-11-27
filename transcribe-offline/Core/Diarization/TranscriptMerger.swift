//
//  TranscriptMerger.swift
//  transcribe-offline
//
//  Merges VTT word timestamps with speaker diarization segments
//  to create speaker-labeled transcripts
//

import Foundation

/// A segment of transcript attributed to a specific speaker
struct DiarizedSegment: Codable, Equatable {
    let speaker: String        // "Speaker 1", "Speaker 2", etc.
    let start: TimeInterval    // Start time in seconds
    let end: TimeInterval      // End time in seconds
    let text: String           // The text spoken in this segment

    var duration: TimeInterval {
        return end - start
    }

    /// Format timestamp as HH:MM:SS or MM:SS
    var formattedTimestamp: String {
        let hours = Int(start) / 3600
        let minutes = (Int(start) % 3600) / 60
        let seconds = Int(start) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Format as "[HH:MM:SS - Speaker N]: text"
    var formattedLine: String {
        return "[\(formattedTimestamp) - \(speaker)]: \(text)"
    }
}

/// Result of merging transcription with speaker diarization
struct DiarizedTranscript: Codable {
    let segments: [DiarizedSegment]
    let speakerCount: Int
    let duration: TimeInterval

    /// Full transcript formatted with speaker labels and timestamps
    var formattedText: String {
        return segments.map { $0.formattedLine }.joined(separator: "\n\n")
    }

    /// Plain text without timestamps (speaker labels only)
    var plainTextWithSpeakers: String {
        return segments.map { "[\($0.speaker)]: \($0.text)" }.joined(separator: "\n\n")
    }

    /// Statistics about speaker distribution
    var speakerStatistics: [String: TimeInterval] {
        var stats: [String: TimeInterval] = [:]
        for segment in segments {
            stats[segment.speaker, default: 0] += segment.duration
        }
        return stats
    }
}

/// Service for merging VTT transcripts with speaker diarization
class TranscriptMerger {

    private let logger = Logger.shared

    /// Merge VTT word-level timestamps with speaker segments
    /// - Parameters:
    ///   - vttTranscript: Word-level timestamps from whisper.cpp
    ///   - speakerSegments: Speaker identification segments
    /// - Returns: Diarized transcript with speaker labels
    func merge(vttTranscript: VTTTranscript, speakerSegments: [SpeakerSegment]) -> DiarizedTranscript {
        logger.info("Merging transcript with \(vttTranscript.words.count) words and \(speakerSegments.count) speaker segments", category: .transcription)

        // Sort segments by start time
        let sortedSegments = speakerSegments.sorted { $0.start < $1.start }

        var diarizedSegments: [DiarizedSegment] = []
        var currentSpeaker: String? = nil
        var currentText: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0

        // Assign each word to a speaker, then correct for word timestamps being imprecise:
        // keep sentences with one clear speaker together and smooth out single-word flips
        var speakers = vttTranscript.words.map { findSpeaker(for: $0, in: sortedSegments) }
        keepSentencesTogether(&speakers, words: vttTranscript.words, segments: sortedSegments)
        smoothSingleWordFlips(&speakers, words: vttTranscript.words)

        // Iterate through words and group them by speaker
        for (word, speaker) in zip(vttTranscript.words, speakers) {

            // If speaker changed, save previous segment
            if let prevSpeaker = currentSpeaker, prevSpeaker != speaker {
                if !currentText.isEmpty {
                    let segment = DiarizedSegment(
                        speaker: prevSpeaker,
                        start: currentStart,
                        end: currentEnd,
                        text: currentText.joined(separator: " ")
                    )
                    diarizedSegments.append(segment)
                    currentText.removeAll()
                }
            }

            // Start new segment or continue current one
            if currentSpeaker != speaker {
                currentSpeaker = speaker
                currentStart = word.start
            }

            currentText.append(word.text)
            currentEnd = word.end
        }

        // Save final segment
        if let speaker = currentSpeaker, !currentText.isEmpty {
            let segment = DiarizedSegment(
                speaker: speaker,
                start: currentStart,
                end: currentEnd,
                text: currentText.joined(separator: " ")
            )
            diarizedSegments.append(segment)
        }

        // Calculate statistics
        let uniqueSpeakers = Set(diarizedSegments.map { $0.speaker })
        let totalDuration = diarizedSegments.last?.end ?? 0

        logger.info("✅ Created diarized transcript with \(diarizedSegments.count) segments and \(uniqueSpeakers.count) speakers", category: .transcription)

        return DiarizedTranscript(
            segments: diarizedSegments,
            speakerCount: uniqueSpeakers.count,
            duration: totalDuration
        )
    }

    /// Find which speaker a word belongs to
    /// - Parameters:
    ///   - word: Timestamped word (or phrase)
    ///   - segments: Sorted speaker segments
    /// - Returns: Speaker label (defaults to "Unknown" if no match)
    private func findSpeaker(for word: TimestampedWord, in segments: [SpeakerSegment]) -> String {
        // Prefer the speaker who talks for most of the word's duration. Word timestamps often
        // include trailing silence, so overlap with actual speech is more reliable than the midpoint.
        var overlaps: [String: TimeInterval] = [:]
        for segment in segments {
            if segment.start >= word.end { break }
            let overlap = min(segment.end, word.end) - max(segment.start, word.start)
            if overlap > 0 {
                overlaps[segment.speaker, default: 0] += overlap
            }
        }

        if let best = overlaps.max(by: { $0.value < $1.value }) {
            return best.key
        }

        let timestamp = (word.start + word.end) / 2.0

        // If no exact match, find closest segment
        // This handles words that fall in gaps between speaker segments
        var closestSegment: SpeakerSegment?
        var minDistance = TimeInterval.infinity

        for segment in segments {
            let distance: TimeInterval
            if timestamp < segment.start {
                distance = segment.start - timestamp
            } else if timestamp > segment.end {
                distance = timestamp - segment.end
            } else {
                distance = 0
            }

            if distance < minDistance {
                minDistance = distance
                closestSegment = segment
            }
        }

        // If word is within 3 seconds of a segment, attribute it to that speaker
        // Increased from 1.0 to reduce "Unknown" labels
        if minDistance < 3.0, let segment = closestSegment {
            return segment.speaker
        }

        // Always assign to nearest speaker if available (eliminates most "Unknown" labels)
        // Only returns "Unknown" if there are literally no speaker segments
        return closestSegment?.speaker ?? "Unknown"
    }

    /// Speaking time per speaker between two timestamps
    private func speakingTime(from start: TimeInterval, to end: TimeInterval, in segments: [SpeakerSegment]) -> [String: TimeInterval] {
        var overlaps: [String: TimeInterval] = [:]
        for segment in segments {
            if segment.start >= end { break }
            let overlap = min(segment.end, end) - max(segment.start, start)
            if overlap > 0 {
                overlaps[segment.speaker, default: 0] += overlap
            }
        }
        return overlaps
    }

    /// Give every word of a sentence to the speaker who talks for most of it. Speakers mostly change
    /// between sentences, and Whisper's word timestamps are not precise enough to split inside one.
    /// A sentence without a clear main speaker (an interruption) keeps its word-by-word speakers.
    private func keepSentencesTogether(_ speakers: inout [String], words: [TimestampedWord], segments: [SpeakerSegment]) {
        var sentenceStart = 0

        for index in words.indices {
            // A sentence ends at closing punctuation or at a pause before the next word
            let endsSentence = words[index].text.last.map { ".?!".contains($0) } ?? false
            let isLastWord = index == words.count - 1
            let pauseFollows = !isLastWord && words[index + 1].start - words[index].end > 0.5
            guard endsSentence || pauseFollows || isLastWord else { continue }

            let range = sentenceStart...index
            sentenceStart = index + 1

            // Single words (cues from a model without word timestamps are whole phrases) need no correction
            guard range.count > 1 else { continue }

            let overlaps = speakingTime(from: words[range.lowerBound].start, to: words[range.upperBound].end, in: segments)
            let total = overlaps.values.reduce(0, +)

            if let main = overlaps.max(by: { $0.value < $1.value }), main.value >= 0.7 * total {
                for wordIndex in range {
                    speakers[wordIndex] = main.key
                }
            }
        }
    }

    /// Reassign a lone short word that sits between two words from the same other speaker.
    /// A complete one-word reply ("Sim.") is kept: only words without closing punctuation are moved.
    private func smoothSingleWordFlips(_ speakers: inout [String], words: [TimestampedWord]) {
        guard speakers.count >= 3 else { return }

        for index in 1..<(speakers.count - 1) {
            let previous = speakers[index - 1]
            guard speakers[index] != previous, speakers[index + 1] == previous else { continue }

            let word = words[index]
            let endsSentence = word.text.last.map { ".?!".contains($0) } ?? false
            let startsSentence = words[index - 1].text.last.map { ".?!".contains($0) } ?? false

            if word.end - word.start < 0.5 && !(endsSentence && startsSentence) {
                speakers[index] = previous
            }
        }
    }

    /// Create a simple speaker-labeled transcript without timestamps
    /// - Parameters:
    ///   - plainText: Plain text transcription
    ///   - speakerSegments: Speaker identification segments
    /// - Returns: Text with speaker labels
    func createSimpleDiarizedText(plainText: String, speakerSegments: [SpeakerSegment]) -> String {
        // This is a fallback method if VTT timestamps aren't available
        // It simply inserts speaker labels at segment boundaries

        let words = plainText.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return plainText }

        // Estimate words per second (rough approximation)
        let totalDuration = speakerSegments.last?.end ?? 1.0
        let wordsPerSecond = Double(words.count) / totalDuration

        var result: [String] = []
        var wordIndex = 0

        for segment in speakerSegments.sorted(by: { $0.start < $1.start }) {
            // Calculate which words belong to this segment
            let startWordIndex = Int(segment.start * wordsPerSecond)
            let endWordIndex = Int(segment.end * wordsPerSecond)

            let segmentWords = words[max(wordIndex, startWordIndex)..<min(words.count, endWordIndex)]

            if !segmentWords.isEmpty {
                result.append("[\(segment.speaker)]: \(segmentWords.joined(separator: " "))")
                wordIndex = endWordIndex
            }
        }

        // Add any remaining words
        if wordIndex < words.count {
            result.append("[Unknown]: \(words[wordIndex...].joined(separator: " "))")
        }

        return result.joined(separator: "\n\n")
    }
}
