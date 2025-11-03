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
    case foundationModels = "foundationModels"

    var displayName: String {
        return "Apple Intelligence"
    }

    var requiresAPIKey: Bool {
        return false
    }

    var isLocal: Bool {
        return true
    }

    var securityLevel: SecurityLevel {
        return .secure
    }

    var securityWarning: String? {
        return nil
    }
}

// MARK: - Security Level

enum SecurityLevel {
    case secure              // Encrypted or local-only
    case requiresUserConsent // Requires explicit user understanding of risks
}
