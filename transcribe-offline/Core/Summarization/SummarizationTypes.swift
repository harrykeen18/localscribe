import Foundation

// MARK: - Shared Types for Summarization

struct SummaryResult: Codable, Equatable {
    let markdown: String
    let model: String?  // Optional model identifier
    let timestamp: Date
    let processingTime: TimeInterval
    let provider: String  // Which provider generated this summary

    init(markdown: String, model: String? = nil, timestamp: Date = Date(), processingTime: TimeInterval, provider: String) {
        self.markdown = markdown
        self.model = model
        self.timestamp = timestamp
        self.processingTime = processingTime
        self.provider = provider
    }
}

enum SummarizationError: LocalizedError {
    case invalidURL
    case networkError(String)
    case apiError(String)
    case invalidResponse
    case timeout
    case providerNotAvailable(String)
    case configurationError(String)
    case responseError(String)
    case noProvidersAvailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid base URL"
        case .networkError(let message):
            return "Network error: \(message)"
        case .apiError(let message):
            return "API error: \(message)"
        case .invalidResponse:
            return "Invalid response"
        case .timeout:
            return "Request timed out"
        case .providerNotAvailable(let provider):
            return "Provider '\(provider)' is not available or not properly configured"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .responseError(let message):
            return "Response error: \(message)"
        case .noProvidersAvailable:
            return "No summarization providers are available. Apple Intelligence must be enabled in System Settings."
        }
    }
}
