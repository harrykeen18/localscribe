import Foundation
import SwiftUI
import Combine

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let logger = Logger.shared

    // Summarization Provider Configuration
    @Published var selectedProvider: SummarizationProviderType? {
        didSet {
            if let provider = selectedProvider {
                UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedProvider")
            }
            logger.info("Summarization provider changed to: \(selectedProvider?.displayName ?? "Auto")", category: .system)
            updateSummarizationManager()
        }
    }

    // Speaker Diarization Configuration
    @Published var enableSpeakerDiarization: Bool {
        didSet {
            UserDefaults.standard.set(enableSpeakerDiarization, forKey: "enableSpeakerDiarization")
            logger.info("Speaker diarization \(enableSpeakerDiarization ? "enabled" : "disabled")", category: .system)
            updateTranscriptionService()
        }
    }

    // Keep raw audio after transcription (off by default; audio is otherwise temporary)
    @Published var keepAudioRecordings: Bool {
        didSet {
            UserDefaults.standard.set(keepAudioRecordings, forKey: "keepAudioRecordings")
            logger.info("Keep audio recordings \(keepAudioRecordings ? "enabled" : "disabled")", category: .system)
        }
    }

    private init() {
        self.keepAudioRecordings = UserDefaults.standard.bool(forKey: "keepAudioRecordings")

        // Always use Apple Intelligence in this release
        self.selectedProvider = .foundationModels

        // Load speaker diarization setting (default: enabled, models are bundled)
        self.enableSpeakerDiarization = UserDefaults.standard.object(forKey: "enableSpeakerDiarization") as? Bool ?? true

        logger.info("AppSettings initialized", category: .system)

        // Update SummarizationManager with selected provider
        updateSummarizationManager()

        // Update TranscriptionService with diarization setting
        updateTranscriptionService()
    }

    private func updateSummarizationManager() {
        SummarizationManager.shared.selectedProviderType = selectedProvider
    }

    private func updateTranscriptionService() {
        TranscriptionService.shared.enableDiarization = enableSpeakerDiarization

        if enableSpeakerDiarization {
            DiarizationService.shared.warmUp()
        }
    }

    func resetToDefaults() {
        selectedProvider = .foundationModels
        enableSpeakerDiarization = true
        keepAudioRecordings = false

        logger.info("Settings reset to defaults", category: .system)
    }
}

// MARK: - Keychain Helper

struct KeychainHelper {
    /// Base query for an item. Builds with a non-release bundle ID (e.g. test builds) keep their
    /// items under their own service, so they never read or replace the release app's secrets.
    private static func itemQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        let releaseBundleID = "transcribe-offline"
        if let bundleID = Bundle.main.bundleIdentifier, bundleID != releaseBundleID {
            query[kSecAttrService as String] = bundleID
        }

        return query
    }

    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!

        var query = itemQuery(for: key)
        query[kSecValueData as String] = data

        // Delete any existing item
        SecItemDelete(query as CFDictionary)

        // Add new item
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        var query = itemQuery(for: key)
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    static func delete(key: String) {
        SecItemDelete(itemQuery(for: key) as CFDictionary)
    }
}
