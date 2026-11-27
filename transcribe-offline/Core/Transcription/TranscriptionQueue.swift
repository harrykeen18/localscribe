//
//  TranscriptionQueue.swift
//  transcribe-offline
//
//  Manages a FIFO queue for audio transcription
//  Processes one item at a time, persists state to disk
//

import Foundation
import Combine

@MainActor
class TranscriptionQueue: ObservableObject {
    // MARK: - Singleton

    static let shared = TranscriptionQueue()

    // MARK: - Types

    struct QueueItem: Identifiable, Codable {
        let id: UUID
        let audioFileURL: URL
        let tracks: RecordingTracks?  // Separate mic/system tracks, when both were recorded
        let recordingDuration: TimeInterval
        let timestamp: Date
        var state: ItemState
        var progress: Double
        var result: TranscriptionResult?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case id, audioFileURL, tracks, recordingDuration, timestamp, state, progress, error
            // Note: result is not persisted to disk (transient)
        }

        init(id: UUID = UUID(), audioFileURL: URL, tracks: RecordingTracks? = nil, recordingDuration: TimeInterval, timestamp: Date = Date()) {
            self.id = id
            self.audioFileURL = audioFileURL
            self.tracks = tracks
            self.recordingDuration = recordingDuration
            self.timestamp = timestamp
            self.state = .pending
            self.progress = 0.0
            self.result = nil
            self.error = nil
        }
    }

    enum ItemState: String, Codable {
        case pending
        case processing
        case completed
        case failed
    }

    // MARK: - Published Properties

    @Published var queue: [QueueItem] = []
    @Published var isProcessing = false

    // MARK: - Private Properties

    private let transcriptionService = TranscriptionService.shared
    private let logger = Logger.shared
    private let persistenceURL: URL
    private var processingTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        // Set up persistence location
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = appSupport.appendingPathComponent("AudioNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        persistenceURL = appDirectory.appendingPathComponent("transcriptionQueue.json")

        // Load persisted queue
        loadQueue()

        logger.info("TranscriptionQueue initialized with \(queue.count) items", category: .transcription)
    }

    // MARK: - Public Methods

    /// Enqueue a new audio file for transcription
    func enqueue(audioFileURL: URL, tracks: RecordingTracks? = nil, recordingDuration: TimeInterval) -> UUID {
        let item = QueueItem(audioFileURL: audioFileURL, tracks: tracks, recordingDuration: recordingDuration)
        queue.append(item)

        logger.info("Enqueued transcription: \(item.id) (\(String(format: "%.1f", recordingDuration))s)", category: .transcription)

        saveQueue()

        // Auto-start processing if not already running
        if !isProcessing {
            Task {
                await processQueue()
            }
        }

        return item.id
    }

    /// Process the queue (called automatically after enqueue)
    func processQueue() async {
        guard !isProcessing else {
            logger.debug("Queue processing already in progress", category: .transcription)
            return
        }

        isProcessing = true
        logger.info("Starting queue processing", category: .transcription)

        defer {
            isProcessing = false
            logger.info("Queue processing stopped", category: .transcription)
        }

        while let pendingIndex = queue.firstIndex(where: { $0.state == .pending }) {
            var item = queue[pendingIndex]

            // Update state to processing
            item.state = .processing
            item.progress = 0.0
            queue[pendingIndex] = item
            saveQueue()

            logger.info("Processing transcription: \(item.id)", category: .transcription)

            // Monitor progress
            let progressTask = Task {
                while transcriptionService.isTranscribing {
                    await MainActor.run {
                        if let index = queue.firstIndex(where: { $0.id == item.id }) {
                            queue[index].progress = transcriptionService.progress
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            do {
                // Transcribe
                let result = try await transcriptionService.transcribe(audioFileURL: item.audioFileURL, tracks: item.tracks)
                progressTask.cancel()

                // Update state to completed
                if let index = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[index].state = .completed
                    queue[index].progress = 1.0
                    queue[index].result = result
                    saveQueue()

                    logger.info("Transcription completed: \(item.id) (\(result.wordCount) words)", category: .transcription)
                }

            } catch {
                progressTask.cancel()

                // Update state to failed
                if let index = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[index].state = .failed
                    queue[index].error = error.localizedDescription
                    saveQueue()

                    logger.error("Transcription failed: \(item.id) - \(error.localizedDescription)", category: .transcription)
                }
            }

            // Small delay between items
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Cancel a specific item (remove from queue)
    func cancel(id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let item = queue[index]

            if item.state == .processing {
                // Can't cancel in-progress transcription easily
                // Mark as failed instead and it will be skipped
                queue[index].state = .failed
                queue[index].error = "Cancelled by user"
                logger.warning("Marked in-progress transcription as cancelled: \(id)", category: .transcription)
            }

            saveQueue()
        }
    }

    /// Remove an item from the queue
    func remove(id: UUID) {
        queue.removeAll { $0.id == id }
        logger.info("Removed item from transcription queue: \(id)", category: .transcription)
        saveQueue()
    }

    /// Retry a failed item
    func retry(id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id && $0.state == .failed }) {
            queue[index].state = .pending
            queue[index].progress = 0.0
            queue[index].error = nil
            queue[index].result = nil

            logger.info("Retrying transcription: \(id)", category: .transcription)
            saveQueue()

            // Auto-start processing
            if !isProcessing {
                Task {
                    await processQueue()
                }
            }
        }
    }

    // MARK: - Persistence

    private func saveQueue() {
        do {
            // Only save items that are not completed (completed items are in history)
            let itemsToSave = queue.filter { $0.state != .completed }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(itemsToSave)
            try data.write(to: persistenceURL, options: .atomic)

            logger.debug("Saved transcription queue (\(itemsToSave.count) items)", category: .file)
        } catch {
            logger.error("Failed to save transcription queue: \(error.localizedDescription)", category: .file)
        }
    }

    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            logger.debug("No persisted transcription queue found", category: .file)
            return
        }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            queue = try decoder.decode([QueueItem].self, from: data)

            logger.info("Loaded transcription queue (\(queue.count) items)", category: .file)

            // Reset stale .processing items to .pending (app was quit while processing)
            var resetCount = 0
            for index in queue.indices {
                if queue[index].state == .processing {
                    logger.warning("Resetting stale .processing item to .pending: \(queue[index].id)", category: .transcription)
                    queue[index].state = .pending
                    queue[index].progress = 0.0
                    queue[index].error = nil
                    resetCount += 1
                }
            }
            if resetCount > 0 {
                logger.info("Reset \(resetCount) stale .processing items to .pending", category: .transcription)
                saveQueue()
            }

            // Resume processing if there are pending items
            if queue.contains(where: { $0.state == .pending }) {
                Task {
                    await processQueue()
                }
            }

        } catch {
            logger.error("Failed to load transcription queue: \(error.localizedDescription)", category: .file)
            queue = []
        }
    }
}
