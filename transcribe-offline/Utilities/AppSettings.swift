import Foundation
import SwiftUI
import Combine

@MainActor
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let logger = Logger.shared

    // Summarization Provider Configuration (Apple Intelligence only in this release)
    @Published var selectedProvider: SummarizationProviderType? {
        didSet {
            if let provider = selectedProvider {
                UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedProvider")
            }
            logger.info("Summarization provider: \(selectedProvider?.displayName ?? "Apple Intelligence")", category: .system)
            updateSummarizationManager()
        }
    }

    private init() {
        // Always use Apple Intelligence in this release
        self.selectedProvider = .foundationModels

        logger.info("AppSettings initialized (Apple Intelligence only)", category: .system)

        // Update SummarizationManager with selected provider
        updateSummarizationManager()
    }

    private func updateSummarizationManager() {
        SummarizationManager.shared.selectedProviderType = selectedProvider
    }

    func resetToDefaults() {
        selectedProvider = .foundationModels
        logger.info("Settings reset to defaults (Apple Intelligence)", category: .system)
    }
}
