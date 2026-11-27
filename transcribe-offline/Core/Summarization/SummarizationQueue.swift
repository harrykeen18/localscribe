//
//  SummarizationQueue.swift
//  transcribe-offline
//
//  Manages a FIFO queue for transcript summarization
//  Processes one item at a time, persists state to disk
//

import Foundation
import Combine

@MainActor
class SummarizationQueue: ObservableObject {
    // MARK: - Singleton

    static let shared = SummarizationQueue()

    // MARK: - Types

    struct QueueItem: Identifiable, Codable {
        let id: UUID
        let transcriptionId: UUID  // Link back to transcription queue item
        let transcript: String
        let diarizedTranscript: String?  // Speaker-labeled transcript for better summarization
        let speakerCount: Int?  // Number of speakers detected
        let transcriptWordCount: Int
        let timestamp: Date
        var state: ItemState
        var result: SummaryResult?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case id, transcriptionId, transcript, diarizedTranscript, speakerCount, transcriptWordCount, timestamp, state, error
            // Note: result is not persisted to disk (transient)
        }

        init(id: UUID = UUID(), transcriptionId: UUID, transcript: String, diarizedTranscript: String? = nil, speakerCount: Int? = nil, wordCount: Int, timestamp: Date = Date()) {
            self.id = id
            self.transcriptionId = transcriptionId
            self.transcript = transcript
            self.diarizedTranscript = diarizedTranscript
            self.speakerCount = speakerCount
            self.transcriptWordCount = wordCount
            self.timestamp = timestamp
            self.state = .pending
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

    private let summarizationManager = SummarizationManager.shared
    private let logger = Logger.shared
    private let persistenceURL: URL
    private var processingTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        // Set up persistence location
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = appSupport.appendingPathComponent("AudioNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        persistenceURL = appDirectory.appendingPathComponent("summarizationQueue.json")

        // Load persisted queue
        loadQueue()

        logger.info("SummarizationQueue initialized with \(queue.count) items", category: .transcription)
    }

    // MARK: - Public Methods

    /// Enqueue a new transcript for summarization
    func enqueue(transcriptionId: UUID, transcript: String, diarizedTranscript: String? = nil, speakerCount: Int? = nil, wordCount: Int) -> UUID {
        let item = QueueItem(
            transcriptionId: transcriptionId,
            transcript: transcript,
            diarizedTranscript: diarizedTranscript,
            speakerCount: speakerCount,
            wordCount: wordCount
        )
        queue.append(item)

        let speakerInfo = speakerCount.map { " with \($0) speakers" } ?? ""
        logger.info("Enqueued summarization: \(item.id) (\(wordCount) words\(speakerInfo))", category: .transcription)

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
        logger.info("Starting summarization queue processing", category: .transcription)

        defer {
            isProcessing = false
            logger.info("Summarization queue processing stopped", category: .transcription)
        }

        while let pendingIndex = queue.firstIndex(where: { $0.state == .pending }) {
            var item = queue[pendingIndex]

            // Update state to processing
            item.state = .processing
            queue[pendingIndex] = item
            saveQueue()

            logger.info("Processing summarization: \(item.id)", category: .transcription)

            do {
                // Summarize (use diarized transcript if available for better speaker attribution)
                let result = try await summarizationManager.summarize(
                    transcript: item.transcript,
                    diarizedTranscript: item.diarizedTranscript,
                    speakerCount: item.speakerCount
                )

                // Update state to completed
                if let index = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[index].state = .completed
                    queue[index].result = result
                    saveQueue()

                    logger.info("Summarization completed: \(item.id) (provider: \(result.provider))", category: .transcription)
                }

            } catch {
                // Update state to failed
                if let index = queue.firstIndex(where: { $0.id == item.id }) {
                    queue[index].state = .failed
                    queue[index].error = error.localizedDescription
                    saveQueue()

                    logger.error("Summarization failed: \(item.id) - \(error.localizedDescription)", category: .transcription)
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
                // Mark as failed - can't easily cancel async summarization
                queue[index].state = .failed
                queue[index].error = "Cancelled by user"
                logger.warning("Marked in-progress summarization as cancelled: \(id)", category: .transcription)
            }

            saveQueue()
        }
    }

    /// Remove an item from the queue
    func remove(id: UUID) {
        queue.removeAll { $0.id == id }
        logger.info("Removed item from summarization queue: \(id)", category: .transcription)
        saveQueue()
    }

    /// Retry a failed item
    func retry(id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id && $0.state == .failed }) {
            queue[index].state = .pending
            queue[index].error = nil
            queue[index].result = nil

            logger.info("Retrying summarization: \(id)", category: .transcription)
            saveQueue()

            // Auto-start processing
            if !isProcessing {
                Task {
                    await processQueue()
                }
            }
        }
    }

    /// Find queue item by transcription ID
    func findByTranscriptionId(_ transcriptionId: UUID) -> QueueItem? {
        return queue.first { $0.transcriptionId == transcriptionId }
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

            logger.debug("Saved summarization queue (\(itemsToSave.count) items)", category: .file)
        } catch {
            logger.error("Failed to save summarization queue: \(error.localizedDescription)", category: .file)
        }
    }

    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            logger.debug("No persisted summarization queue found", category: .file)
            return
        }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            queue = try decoder.decode([QueueItem].self, from: data)

            logger.info("Loaded summarization queue (\(queue.count) items)", category: .file)

            // Reset stale .processing items to .pending (app was quit while processing)
            var resetCount = 0
            for index in queue.indices {
                if queue[index].state == .processing {
                    logger.warning("Resetting stale .processing item to .pending: \(queue[index].id)", category: .transcription)
                    queue[index].state = .pending
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
            logger.error("Failed to load summarization queue: \(error.localizedDescription)", category: .file)
            queue = []
        }
    }
}
