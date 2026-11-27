//
//  TrackSpeakerRefiner.swift
//  transcribe-offline
//
//  Uses the separate microphone and system-audio tracks to correct and name
//  the speakers found by voice diarization.
//
//  The system track only ever contains remote participants, and the microphone
//  only picks up remote audio while the system track is playing (speaker bleed
//  when no headphones are worn). So:
//    - speech on the microphone while the system track is silent is local
//    - speech on the system track while the microphone is silent is remote
//  Everything else (both tracks active) is left to the voice diarizer.
//
//  Foundation only: this file is shared with Scripts/diarization-harness.
//

import Foundation

/// Speaker segment with timestamp and speaker ID
nonisolated struct SpeakerSegment: Codable, Equatable, Sendable {
    let speaker: String      // "You", "Speaker 1", "Speaker 2", etc.
    let start: TimeInterval  // Start time in seconds
    let end: TimeInterval    // End time in seconds

    var duration: TimeInterval {
        return end - start
    }
}

nonisolated struct TrackSpeakerRefiner {

    /// Label given to the local speaker when the microphone track has a single voice
    static let localSpeakerLabel = "You"

    /// Analysis frame length in seconds
    static let frameSeconds = 0.1

    /// Minimum system-track speech before the tracks are trusted to separate local from remote
    private static let minimumSystemSeconds = 5.0

    /// Minimum microphone-only speech before a local speaker is named
    private static let minimumLocalSeconds = 2.0

    /// System activity is extended by this many frames to cover speaker-to-microphone delay and room echo
    private static let echoTailFrames = 3

    /// Speakers with less than this share of all labelled speech are merged into their neighbours
    private static let minorSpeakerShare = 0.05

    struct Result: Sendable {
        let segments: [SpeakerSegment]
        /// True when the tracks were used; false when segments were only renumbered
        let usedTracks: Bool
        /// True when a single local speaker was identified and labelled
        let namedLocalSpeaker: Bool
    }

    // MARK: - Public API

    /// Refine voice-diarization segments using the two recorded tracks
    /// - Parameters:
    ///   - segments: Segments from voice diarization of the mixed audio (any speaker IDs)
    ///   - microphone: Microphone track samples
    ///   - system: System audio track samples
    ///   - sampleRate: Sample rate of both tracks
    static func refine(segments: [SpeakerSegment], microphone: [Float], system: [Float], sampleRate: Int) -> Result {
        let micActive = activity(microphone, sampleRate: sampleRate)
        let systemActive = activity(system, sampleRate: sampleRate)

        let lastSegmentEnd = segments.map { $0.end }.max() ?? 0
        let frameCount = max(micActive.count, systemActive.count, Int((lastSegmentEnd / frameSeconds).rounded(.up)))

        guard frameCount > 0 else {
            return Result(segments: [], usedTracks: false, namedLocalSpeaker: false)
        }

        func isActive(_ track: [Bool], _ frame: Int) -> Bool {
            return frame < track.count && track[frame]
        }

        // Diarizer label per frame
        var labels = [String?](repeating: nil, count: frameCount)
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let first = max(0, Int(segment.start / frameSeconds))
            let last = min(frameCount, Int((segment.end / frameSeconds).rounded(.up)))
            guard first < last else { continue }
            for frame in first..<last {
                labels[frame] = segment.speaker
            }
        }

        // Without enough remote speech the tracks say nothing about who is who (e.g. an in-person meeting)
        let systemSeconds = Double(systemActive.filter { $0 }.count) * frameSeconds
        guard systemSeconds >= minimumSystemSeconds else {
            return Result(segments: renumber(segments: segments), usedTracks: false, namedLocalSpeaker: false)
        }

        // When the microphone is active for most of the remote speech it is hearing the loudspeakers
        // (no headphones). System activity is then padded to cover the delay and echo of that audio.
        let systemFrameCount = systemActive.filter { $0 }.count
        let bothFrameCount = (0..<frameCount).filter { isActive(systemActive, $0) && isActive(micActive, $0) }.count
        let microphoneHearsSystem = Double(bothFrameCount) >= 0.5 * Double(systemFrameCount)

        var systemPadded = [Bool](repeating: false, count: frameCount)
        for frame in 0..<frameCount where isActive(systemActive, frame) {
            let first = max(0, frame - (microphoneHearsSystem ? 1 : 0))
            let last = min(frameCount - 1, frame + (microphoneHearsSystem ? echoTailFrames : 0))
            for padded in first...last {
                systemPadded[padded] = true
            }
        }

        let localOnly = (0..<frameCount).map { isActive(micActive, $0) && !systemPadded[$0] }
        let remoteOnly = (0..<frameCount).map { isActive(systemActive, $0) && !isActive(micActive, $0) }

        // Which diarized speakers account for the microphone-only speech?
        var localCounts: [String: Int] = [:]
        for frame in 0..<frameCount where localOnly[frame] {
            if let label = labels[frame] {
                localCounts[label, default: 0] += 1
            }
        }
        let localFrames = localOnly.filter { $0 }.count
        let labelledLocalFrames = localCounts.values.reduce(0, +)

        // Several substantial voices on the microphone means several people in the room:
        // keep the diarizer's labels for them rather than calling everyone "You"
        let substantialLocalSpeakers = localCounts.filter { _, count in
            Double(count) * frameSeconds >= 5.0 && Double(count) >= 0.2 * Double(labelledLocalFrames)
        }
        let hasSingleLocalSpeaker = substantialLocalSpeakers.count <= 1
            && Double(localFrames) * frameSeconds >= minimumLocalSeconds

        let localLabel = "\u{0}local"
        let remoteLabel = "\u{0}remote"

        if hasSingleLocalSpeaker {
            // The diarized voice that best matches the microphone-only speech is the local speaker everywhere
            if let localSpeaker = localCounts.max(by: { $0.value < $1.value })?.key {
                for frame in 0..<frameCount where labels[frame] == localSpeaker {
                    labels[frame] = localLabel
                }
            }

            // Microphone-only speech is always the local speaker
            for frame in 0..<frameCount where localOnly[frame] {
                labels[frame] = localLabel
            }
        }

        // System-only speech can never be the local speaker: give it to the nearest remote speaker
        let localSpeakers: Set<String> = hasSingleLocalSpeaker ? [localLabel] : Set(substantialLocalSpeakers.keys)
        let remoteFrames = (0..<frameCount).filter { frame in
            guard let label = labels[frame] else { return false }
            return !localSpeakers.contains(label)
        }

        for frame in 0..<frameCount where remoteOnly[frame] {
            if let label = labels[frame], !localSpeakers.contains(label) {
                continue
            }
            labels[frame] = nearestLabel(to: frame, in: remoteFrames, labels: labels) ?? remoteLabel
        }

        // Audio on the system track that the voice diarizer left unlabelled is still a remote speaker
        for frame in 0..<frameCount where labels[frame] == nil && isActive(systemActive, frame) {
            labels[frame] = nearestLabel(to: frame, in: remoteFrames, labels: labels) ?? remoteLabel
        }

        mergeMinorSpeakers(&labels, keeping: localSpeakers)

        // Name speakers: the local speaker is "You", everyone else is numbered in order of appearance
        var renaming: [String: String] = [:]
        if hasSingleLocalSpeaker {
            renaming[localLabel] = localSpeakerLabel
        }

        return Result(
            segments: buildSegments(from: labels, renaming: renaming),
            usedTracks: true,
            namedLocalSpeaker: hasSingleLocalSpeaker
        )
    }

    /// Renumber diarizer speaker IDs as "Speaker 1", "Speaker 2", ... in order of appearance,
    /// merging minor speakers into their neighbours
    static func renumber(segments: [SpeakerSegment]) -> [SpeakerSegment] {
        let lastSegmentEnd = segments.map { $0.end }.max() ?? 0
        var labels = [String?](repeating: nil, count: Int((lastSegmentEnd / frameSeconds).rounded(.up)))
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let first = max(0, Int(segment.start / frameSeconds))
            let last = min(labels.count, Int((segment.end / frameSeconds).rounded(.up)))
            guard first < last else { continue }
            for frame in first..<last {
                labels[frame] = segment.speaker
            }
        }

        mergeMinorSpeakers(&labels, keeping: [])
        return buildSegments(from: labels, renaming: [:])
    }

    /// Speech activity per frame: true where the level is clearly above the track's noise floor
    static func activity(_ samples: [Float], sampleRate: Int) -> [Bool] {
        let frameSamples = Int(Double(sampleRate) * frameSeconds)
        guard frameSamples > 0, samples.count >= frameSamples else { return [] }

        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameSamples)

        var start = 0
        while start + frameSamples <= samples.count {
            var sum: Float = 0
            for index in start..<start + frameSamples {
                sum += samples[index] * samples[index]
            }
            levels.append((sum / Float(frameSamples)).squareRoot())
            start += frameSamples
        }

        // Roughly -40 dBFS, raised when the track has a steady background (fan noise, room tone)
        let noiseFloor = levels.sorted()[levels.count / 10]
        let threshold = max(0.01, noiseFloor * 3)

        return levels.map { $0 > threshold }
    }

    // MARK: - Private Methods

    /// Give the speech of minor speakers to the nearest major speaker. On long recordings the voice
    /// diarizer occasionally splits off short stretches of one voice (laughter, a change of tone, a
    /// burst of crosstalk) as a new speaker, which then appears as an extra participant.
    private static func mergeMinorSpeakers(_ labels: inout [String?], keeping protected: Set<String>) {
        var counts: [String: Int] = [:]
        for case let label? in labels {
            counts[label, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)

        let minor = Set(counts.filter { label, count in
            !protected.contains(label) && Double(count) < minorSpeakerShare * Double(total)
        }.keys)
        guard !minor.isEmpty, minor.count < counts.count else { return }

        let majorFrames = labels.indices.filter { labels[$0].map { !minor.contains($0) } ?? false }
        let original = labels
        for frame in labels.indices where original[frame].map(minor.contains) ?? false {
            labels[frame] = nearestLabel(to: frame, in: majorFrames, labels: original)
        }
    }

    /// Label of the closest frame in `candidates` (sorted frame indices)
    private static func nearestLabel(to frame: Int, in candidates: [Int], labels: [String?]) -> String? {
        guard !candidates.isEmpty else { return nil }

        // Binary search for the first candidate at or after the frame
        var low = 0
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle] < frame {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let after = low < candidates.count ? candidates[low] : nil
        let before = low > 0 ? candidates[low - 1] : nil

        switch (before, after) {
        case let (before?, after?):
            return labels[(frame - before) <= (after - frame) ? before : after]
        case let (before?, nil):
            return labels[before]
        case let (nil, after?):
            return labels[after]
        default:
            return nil
        }
    }

    /// Turn per-frame labels back into segments, numbering unnamed speakers in order of appearance
    private static func buildSegments(from labels: [String?], renaming: [String: String]) -> [SpeakerSegment] {
        var names = renaming
        var numbered = 0
        var segments: [SpeakerSegment] = []

        var runStart = 0
        for frame in 0...labels.count {
            let label = frame < labels.count ? labels[frame] : nil
            let runLabel = runStart < labels.count ? labels[runStart] : nil

            if frame == labels.count || label != runLabel {
                if let runLabel {
                    let name: String
                    if let existing = names[runLabel] {
                        name = existing
                    } else {
                        numbered += 1
                        name = "Speaker \(numbered)"
                        names[runLabel] = name
                    }
                    segments.append(SpeakerSegment(
                        speaker: name,
                        start: Double(runStart) * frameSeconds,
                        end: Double(frame) * frameSeconds
                    ))
                }
                runStart = frame
            }
        }

        return segments
    }
}
