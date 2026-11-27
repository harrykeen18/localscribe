import Foundation
import SwiftUI
import Combine

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let logger = Logger.shared

    // Ollama Local Configuration
    @Published var ollamaLocalBaseURL: String {
        didSet {
            let trimmed = ollamaLocalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != ollamaLocalBaseURL {
                ollamaLocalBaseURL = trimmed
                return
            }
            UserDefaults.standard.set(ollamaLocalBaseURL, forKey: "ollamaLocalBaseURL")
            updateOllamaService()
        }
    }

    @Published var ollamaLocalModel: String {
        didSet {
            UserDefaults.standard.set(ollamaLocalModel, forKey: "ollamaLocalModel")
            updateOllamaService()
        }
    }

    @Published var ollamaLocalAPIKey: String {
        didSet {
            if ollamaLocalAPIKey.isEmpty {
                KeychainHelper.delete(key: "ollamaLocalAPIKey")
            } else {
                KeychainHelper.save(key: "ollamaLocalAPIKey", value: ollamaLocalAPIKey)
            }
            updateOllamaService()
        }
    }

    // Ollama Remote Configuration
    @Published var ollamaRemoteBaseURL: String {
        didSet {
            let trimmed = ollamaRemoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != ollamaRemoteBaseURL {
                ollamaRemoteBaseURL = trimmed
                return
            }
            UserDefaults.standard.set(ollamaRemoteBaseURL, forKey: "ollamaRemoteBaseURL")
            updateOllamaService()
        }
    }

    @Published var ollamaRemoteModel: String {
        didSet {
            UserDefaults.standard.set(ollamaRemoteModel, forKey: "ollamaRemoteModel")
            updateOllamaService()
        }
    }

    @Published var ollamaRemoteAPIKey: String {
        didSet {
            if ollamaRemoteAPIKey.isEmpty {
                KeychainHelper.delete(key: "ollamaRemoteAPIKey")
            } else {
                KeychainHelper.save(key: "ollamaRemoteAPIKey", value: ollamaRemoteAPIKey)
            }
            updateOllamaService()
        }
    }

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

        // Load Ollama Local settings
        self.ollamaLocalBaseURL = UserDefaults.standard.string(forKey: "ollamaLocalBaseURL") ?? "http://localhost:11434"
        self.ollamaLocalModel = UserDefaults.standard.string(forKey: "ollamaLocalModel") ?? "qwen2.5"
        self.ollamaLocalAPIKey = KeychainHelper.load(key: "ollamaLocalAPIKey") ?? ""

        // Load Ollama Remote settings
        self.ollamaRemoteBaseURL = UserDefaults.standard.string(forKey: "ollamaRemoteBaseURL") ?? ""
        self.ollamaRemoteModel = UserDefaults.standard.string(forKey: "ollamaRemoteModel") ?? "qwen2.5"
        self.ollamaRemoteAPIKey = KeychainHelper.load(key: "ollamaRemoteAPIKey") ?? ""

        // Load provider selection (defaults to Apple Intelligence)
        if let savedProviderRaw = UserDefaults.standard.string(forKey: "selectedProvider"),
           let savedProvider = SummarizationProviderType(rawValue: savedProviderRaw) {
            self.selectedProvider = savedProvider
        } else {
            self.selectedProvider = .foundationModels  // Default to Apple Intelligence
        }

        // Load speaker diarization setting (default: enabled, models are bundled)
        self.enableSpeakerDiarization = UserDefaults.standard.object(forKey: "enableSpeakerDiarization") as? Bool ?? true

        logger.info("AppSettings initialized", category: .system)

        // Configure OllamaService with loaded settings
        updateOllamaService()

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

    private func updateOllamaService() {
        // Configure local service
        let localAPIKey = ollamaLocalAPIKey.isEmpty ? nil : ollamaLocalAPIKey
        OllamaLocalService.shared.configure(baseURL: ollamaLocalBaseURL, model: ollamaLocalModel, apiKey: localAPIKey)

        // Configure remote service
        let remoteAPIKey = ollamaRemoteAPIKey.isEmpty ? nil : ollamaRemoteAPIKey
        OllamaRemoteService.shared.configure(baseURL: ollamaRemoteBaseURL, model: ollamaRemoteModel, apiKey: remoteAPIKey)
    }

    func resetToDefaults() {
        ollamaLocalBaseURL = "http://localhost:11434"
        ollamaLocalModel = "qwen2.5"
        ollamaLocalAPIKey = ""

        ollamaRemoteBaseURL = ""
        ollamaRemoteModel = "qwen2.5"
        ollamaRemoteAPIKey = ""

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
