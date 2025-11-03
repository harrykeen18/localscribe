import Foundation

// MARK: - Summarization Provider Protocol

/// Protocol that all summarization providers must implement
@MainActor
protocol SummarizationProvider {
    /// Unique identifier for this provider
    var providerName: String { get }

    /// Display name for UI
    var displayName: String { get }

    /// Check if this provider is currently available and properly configured
    func isAvailable() async -> Bool

    /// Perform summarization on the given transcript
    /// - Parameter transcript: The full text transcript to summarize
    /// - Returns: A SummaryResult containing the markdown-formatted summary
    /// - Throws: SummarizationError if summarization fails
    func summarize(transcript: String) async throws -> SummaryResult

    /// Generate a concise title from a summary
    /// - Parameter summary: The markdown-formatted summary to generate a title from
    /// - Returns: A concise title string (typically 5-10 words)
    /// - Throws: SummarizationError if title generation fails
    func generateTitle(from summary: String) async throws -> String

    /// Test the connection/availability (for UI feedback)
    func testConnection() async throws
}

// MARK: - Provider Type

enum SummarizationProviderType: String, Codable, CaseIterable {
    case ollamaLocal = "ollamaLocal"
    case foundationModels = "foundationModels"
    case ollamaRemote = "ollamaRemote"

    var displayName: String {
        switch self {
        case .foundationModels:
            return "Apple Intelligence"
        case .ollamaLocal:
            return "Ollama (Local/LAN)"
        case .ollamaRemote:
            return "Ollama (Remote/Custom)"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .foundationModels, .ollamaLocal, .ollamaRemote:
            return false
        }
    }

    var isLocal: Bool {
        switch self {
        case .foundationModels, .ollamaLocal:
            return true
        case .ollamaRemote:
            return false  // May connect to remote servers
        }
    }

    var securityLevel: SecurityLevel {
        switch self {
        case .foundationModels, .ollamaLocal:
            return .secure
        case .ollamaRemote:
            return .requiresUserConsent
        }
    }

    var securityWarning: String? {
        switch self {
        case .foundationModels, .ollamaLocal:
            return nil
        case .ollamaRemote:
            return "⚠️ This option allows unencrypted HTTP connections to any server. Only use with trusted networks like Tailscale, VPN, or configure your Ollama server with HTTPS."
        }
    }
}

// MARK: - Security Level

enum SecurityLevel {
    case secure              // Encrypted or local-only
    case requiresUserConsent // Requires explicit user understanding of risks
}
