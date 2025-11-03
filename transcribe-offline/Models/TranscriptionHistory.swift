import Foundation
import SwiftUI
import Combine
import CryptoKit

// MARK: - Transcription Model

enum SummaryStatus: String, Codable, Equatable {
    case pending        // Summary not yet generated
    case inProgress     // Currently generating
    case completed      // Summary successfully generated
    case failed         // Summarization failed
}

struct Transcription: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let date: Date
    var duration: String
    var summary: String
    var transcript: String
    var wordCount: Int
    var isPlaceholder: Bool
    var summaryStatus: SummaryStatus
    var summaryProvider: String?  // Which provider generated the summary

    init(id: UUID = UUID(), title: String, date: Date, duration: String, summary: String, transcript: String, wordCount: Int, isPlaceholder: Bool = false, summaryStatus: SummaryStatus = .completed, summaryProvider: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.summary = summary
        self.transcript = transcript
        self.wordCount = wordCount
        self.isPlaceholder = isPlaceholder
        self.summaryStatus = summaryStatus
        self.summaryProvider = summaryProvider
    }
}

// MARK: - History Manager

@MainActor
class TranscriptionHistoryManager: ObservableObject {
    static let shared = TranscriptionHistoryManager()

    @Published var transcriptions: [Transcription] = []

    private let logger = Logger.shared
    private let fileURL: URL

    init() {
        // Set up file URL in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = appSupport.appendingPathComponent("AudioNotes", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)

        fileURL = appDirectory.appendingPathComponent("history.json")

        logger.info("History file location: \(fileURL.path)", category: .file)

        // Load existing history
        load()
    }

    // MARK: - Public Methods

    func add(_ transcription: Transcription) {
        transcriptions.insert(transcription, at: 0)
        save()
        logger.info("Added transcription: \(transcription.title)", category: .file)
    }

    func delete(_ transcription: Transcription) {
        transcriptions.removeAll { $0.id == transcription.id }
        save()
        logger.info("Deleted transcription: \(transcription.title)", category: .file)
    }

    func delete(at offsets: IndexSet) {
        transcriptions.remove(atOffsets: offsets)
        save()
        logger.info("Deleted \(offsets.count) transcription(s)", category: .file)
    }

    func update(_ transcription: Transcription) {
        if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
            transcriptions[index] = transcription
            save()
            logger.info("Updated transcription: \(transcription.title)", category: .file)
        }
    }

    // MARK: - Grouping

    struct GroupedTranscriptions {
        let today: [Transcription]
        let previous7Days: [Transcription]
        let older: [Transcription]
    }

    func getGrouped() -> GroupedTranscriptions {
        let now = Date()
        let calendar = Calendar.current

        let today = transcriptions.filter { transcription in
            calendar.isDateInToday(transcription.date)
        }

        let previous7Days = transcriptions.filter { transcription in
            let daysAgo = calendar.dateComponents([.day], from: transcription.date, to: now).day ?? 0
            return daysAgo >= 1 && daysAgo < 7
        }

        let older = transcriptions.filter { transcription in
            let daysAgo = calendar.dateComponents([.day], from: transcription.date, to: now).day ?? 0
            return daysAgo >= 7
        }

        return GroupedTranscriptions(today: today, previous7Days: previous7Days, older: older)
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted

            let jsonData = try encoder.encode(transcriptions)

            // Encrypt data before writing
            let encryptedData = try encryptData(jsonData)
            try encryptedData.write(to: fileURL, options: .atomic)

            logger.debug("Saved \(transcriptions.count) encrypted transcriptions to disk", category: .file)
        } catch {
            logger.error("Failed to save history: \(error.localizedDescription)", category: .file)
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("No existing history file found, starting fresh", category: .file)
            return
        }

        do {
            let encryptedData = try Data(contentsOf: fileURL)

            // Try to decrypt first (new encrypted format)
            let jsonData: Data
            if let decryptedData = try? decryptData(encryptedData) {
                jsonData = decryptedData
                logger.debug("Loaded encrypted transcriptions", category: .file)
            } else {
                // Fall back to unencrypted (migration from old format)
                logger.info("Detected unencrypted history file, will migrate to encrypted", category: .file)
                jsonData = encryptedData
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            transcriptions = try decoder.decode([Transcription].self, from: jsonData)

            // Migrate old transcriptions without summaryStatus
            var needsSave = false
            for index in transcriptions.indices {
                // Check if summary has ⚠️ prefix (old failed state)
                if transcriptions[index].summary.hasPrefix("⚠️") {
                    transcriptions[index].summaryStatus = .failed
                    needsSave = true
                    logger.info("Migrated failed transcription: \(transcriptions[index].title)", category: .file)
                }
            }

            // Always save after loading unencrypted file (to encrypt it)
            if jsonData == encryptedData {
                logger.info("Migrating \(transcriptions.count) transcriptions to encrypted format", category: .file)
                needsSave = true
            }

            if needsSave {
                save()
            }

            logger.info("Loaded \(transcriptions.count) transcriptions from disk", category: .file)
        } catch {
            logger.error("Failed to load history: \(error.localizedDescription)", category: .file)
            transcriptions = []
        }
    }

    // MARK: - Encryption
    //
    // PRIVACY: All transcripts are encrypted at rest using AES-256-GCM.
    // This ensures that even if the file system is compromised, transcript
    // content remains confidential. The encryption key is stored in macOS
    // Keychain and protected by the user's login password.

    /// Encrypts data using AES-GCM with key from Keychain
    private func encryptData(_ data: Data) throws -> Data {
        let key = try KeychainManager.shared.getEncryptionKey()
        let sealedBox = try AES.GCM.seal(data, using: key)

        // Combine nonce + ciphertext + tag into single Data blob
        guard let combined = sealedBox.combined else {
            throw EncryptionError.failedToSeal
        }

        return combined
    }

    /// Decrypts data using AES-GCM with key from Keychain
    private func decryptData(_ data: Data) throws -> Data {
        let key = try KeychainManager.shared.getEncryptionKey()

        // Reconstruct sealed box from combined data
        let sealedBox = try AES.GCM.SealedBox(combined: data)

        // Decrypt and verify
        let decryptedData = try AES.GCM.open(sealedBox, using: key)

        return decryptedData
    }
}

// MARK: - Encryption Errors

enum EncryptionError: LocalizedError {
    case failedToSeal

    var errorDescription: String? {
        switch self {
        case .failedToSeal:
            return "Failed to seal encrypted data"
        }
    }
}

// MARK: - Helper Extensions

extension Transcription {
    /// Format date for display in sidebar
    func formattedDate() -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            // Show time for today
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
            // Show day name for last 7 days
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            // Show date for older
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    /// Format full date/time for detail view
    func formattedFullDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
