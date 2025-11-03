import Foundation
import Combine

struct SummaryResult: Codable, Equatable {
    let markdown: String
    let model: String?  // Optional for non-Ollama providers
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
            return "No summarization providers are available. Please configure at least one provider in Settings."
        }
    }
}

enum OllamaAPIType {
    case openAI  // /v1/chat/completions (OpenAI-compatible)
    case native  // /api/generate (Native Ollama)
}

@MainActor
class OllamaLocalService: ObservableObject, SummarizationProvider {
    static let shared = OllamaLocalService()

    // SummarizationProvider conformance
    var providerName: String { "ollamaLocal" }
    var displayName: String { "Ollama (Local/LAN)" }

    @Published var isProcessing = false
    @Published var currentAPIType: OllamaAPIType = .native  // Track which API is being used

    private let logger = Logger.shared
    private let timeoutInterval: TimeInterval = 1200 // 20 minutes for LLM processing
    private let healthCheckTimeout: TimeInterval = 10 // 10 seconds for quick health checks

    // Configuration (will be loaded from settings later)
    private var baseURL: String = "http://localhost:11434"
    private var model: String = "llama3.1"
    private var apiKey: String? = nil // Optional for auth-protected instances
    private var preferredAPIType: OllamaAPIType = .native  // User preference

    private init() {
        logger.info("OllamaLocalService initialized", category: .transcription)
    }

    // MARK: - SummarizationProvider Protocol

    func isAvailable() async -> Bool {
        // Check if configuration looks valid
        guard !baseURL.isEmpty, !model.isEmpty else {
            logger.info("Ollama not available: missing configuration", category: .transcription)
            return false
        }

        // Try a quick health check
        do {
            try await checkHealth()
            logger.info("Ollama is available", category: .transcription)
            return true
        } catch {
            logger.info("Ollama not available: \(error.localizedDescription)", category: .transcription)
            return false
        }
    }

    // MARK: - Configuration

    func configure(baseURL: String, model: String, apiKey: String? = nil, apiType: OllamaAPIType = .native) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.apiKey = apiKey
        self.preferredAPIType = apiType
        self.currentAPIType = apiType
        logger.info("Ollama configured: \(self.baseURL), model: \(model), API: \(apiType)", category: .transcription)
    }

    // MARK: - Summarization

    func summarize(transcript: String) async throws -> SummaryResult {
        guard !isProcessing else {
            throw SummarizationError.apiError("Already processing another request")
        }

        logger.info("Starting summarization with Ollama", category: .transcription)
        isProcessing = true

        defer {
            isProcessing = false
        }

        let startTime = Date()

        do {
            let summary = try await performSummarization(transcript: transcript)
            let duration = Date().timeIntervalSince(startTime)

            logger.info("Summarization completed in \(String(format: "%.2f", duration))s", category: .transcription)

            return SummaryResult(
                markdown: summary,
                model: model,
                timestamp: Date(),
                processingTime: duration,
                provider: displayName
            )
        } catch {
            logger.error("Summarization failed: \(error.localizedDescription)", category: .transcription)
            throw error
        }
    }

    // MARK: - Private Methods

    private func performSummarization(transcript: String) async throws -> String {
        // Try preferred API first
        do {
            return try await performSummarizationWithAPI(transcript: transcript, apiType: currentAPIType)
        } catch let error as SummarizationError {
            // If we get a 404, try the other API
            if case .apiError(let message) = error, message.contains("404") {
                logger.warning("API endpoint not found, trying alternative API", category: .transcription)
                let alternativeAPI: OllamaAPIType = (currentAPIType == .native) ? .openAI : .native
                do {
                    let result = try await performSummarizationWithAPI(transcript: transcript, apiType: alternativeAPI)
                    // Success! Update the current API type for future requests
                    currentAPIType = alternativeAPI
                    logger.info("Switched to \(alternativeAPI) API", category: .transcription)
                    return result
                } catch {
                    // Both failed, throw the original error
                    throw error
                }
            }
            throw error
        }
    }

    private func performSummarizationWithAPI(transcript: String, apiType: OllamaAPIType) async throws -> String {
        switch apiType {
        case .openAI:
            return try await performOpenAISummarization(transcript: transcript)
        case .native:
            return try await performNativeSummarization(transcript: transcript)
        }
    }

    // OpenAI-compatible API (/v1/chat/completions)
    private func performOpenAISummarization(transcript: String) async throws -> String {
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)v1/chat/completions" : "\(baseURL)/v1/chat/completions"

        guard let url = URL(string: urlString) else {
            throw SummarizationError.invalidURL
        }

        logger.info("Ollama URL (OpenAI): \(urlString)", category: .transcription)

        let payload = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: createSystemPrompt()),
                ChatMessage(role: "user", content: transcript)
            ],
            temperature: 0.2,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            logger.debug("Using API key authentication", category: .transcription)
        }

        request.timeoutInterval = timeoutInterval

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)

        logger.debug("Sending request to Ollama (OpenAI API)...", category: .transcription)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.invalidResponse
        }

        logger.debug("Ollama response status: \(httpResponse.statusCode)", category: .transcription)

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Ollama API error (\(httpResponse.statusCode)): \(errorMessage)", category: .transcription)
            throw SummarizationError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let decoder = JSONDecoder()
        let chatResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

        guard let choice = chatResponse.choices.first,
              let content = choice.message.content else {
            throw SummarizationError.invalidResponse
        }

        logger.info("Successfully received summary from Ollama (OpenAI API)", category: .transcription)

        return content
    }

    // Native Ollama API (/api/generate)
    private func performNativeSummarization(transcript: String) async throws -> String {
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)api/generate" : "\(baseURL)/api/generate"

        guard let url = URL(string: urlString) else {
            throw SummarizationError.invalidURL
        }

        logger.info("Ollama URL (Native): \(urlString)", category: .transcription)

        // Combine system prompt and transcript for native API
        let fullPrompt = """
        \(createSystemPrompt())

        Transcript:
        \(transcript)
        """

        let payload = NativeGenerateRequest(
            model: model,
            prompt: fullPrompt,
            stream: false,
            options: NativeOptions(temperature: 0.2)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            logger.debug("Using API key authentication", category: .transcription)
        }

        request.timeoutInterval = timeoutInterval

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)

        logger.debug("Sending request to Ollama (Native API)...", category: .transcription)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.invalidResponse
        }

        logger.debug("Ollama response status: \(httpResponse.statusCode)", category: .transcription)

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Ollama API error (\(httpResponse.statusCode)): \(errorMessage)", category: .transcription)
            throw SummarizationError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let decoder = JSONDecoder()
        let nativeResponse = try decoder.decode(NativeGenerateResponse.self, from: data)

        logger.info("Successfully received summary from Ollama (Native API)", category: .transcription)

        return nativeResponse.response
    }

    private func createSystemPrompt() -> String {
        """
        You are an expert note-taking assistant. Your task is to transform transcripts into well-structured, concise Markdown notes.

        Follow this format:

        ## Overview
        A brief 1-2 sentence overview of what was discussed.

        ## Key Points
        - Main topic 1 with brief description
        - Main topic 2 with brief description
        - (continue as needed)

        ## Decisions Made
        - Decision 1
        - Decision 2
        - (if applicable)

        ## Action Items
        - Action item (if a specific person is clearly mentioned in the transcript as responsible, include their name, otherwise just describe the action)
        - (if applicable)

        Guidelines:
        - If people are named in the conversation, reference them by name when relevant to key points, decisions, or actions
        - Be concise but comprehensive
        - Use bullet points and headings for clarity
        - Extract actionable items when mentioned
        - Preserve important details like names, dates, and numbers
        - If the transcript is unclear or empty, say so briefly
        """
    }

    // MARK: - Testing

    /// Quick health check using /api/tags endpoint (lightweight, no inference)
    private func checkHealth() async throws {
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)api/tags" : "\(baseURL)/api/tags"

        guard let url = URL(string: urlString) else {
            throw SummarizationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = healthCheckTimeout

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw SummarizationError.apiError("Health check failed with status \(httpResponse.statusCode)")
        }
    }

    func generateTitle(from summary: String) async throws -> String {
        logger.info("Generating title with Ollama Local", category: .transcription)

        let prompt = """
        Based on the following meeting summary, generate a concise, descriptive title (5-10 words maximum).
        The title should capture the main topic or purpose of the meeting.
        Respond with ONLY the title text, no quotes, no extra formatting.

        Summary:
        \(summary)
        """

        let urlString: String
        if currentAPIType == .openAI {
            urlString = baseURL.hasSuffix("/") ? "\(baseURL)v1/chat/completions" : "\(baseURL)/v1/chat/completions"
        } else {
            urlString = baseURL.hasSuffix("/") ? "\(baseURL)api/generate" : "\(baseURL)/api/generate"
        }

        guard let url = URL(string: urlString) else {
            throw SummarizationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.timeoutInterval = timeoutInterval

        let encoder = JSONEncoder()

        if currentAPIType == .openAI {
            let payload = ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(role: "user", content: prompt)
                ],
                temperature: 0.3,
                stream: false
            )
            request.httpBody = try encoder.encode(payload)
        } else {
            let payload = NativeGenerateRequest(
                model: model,
                prompt: prompt,
                stream: false,
                options: NativeOptions(temperature: 0.3)
            )
            request.httpBody = try encoder.encode(payload)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizationError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let decoder = JSONDecoder()
        let title: String

        if currentAPIType == .openAI {
            let chatResponse = try decoder.decode(ChatCompletionResponse.self, from: data)
            guard let choice = chatResponse.choices.first,
                  let content = choice.message.content else {
                throw SummarizationError.invalidResponse
            }
            title = content
        } else {
            let nativeResponse = try decoder.decode(NativeGenerateResponse.self, from: data)
            title = nativeResponse.response
        }

        // Clean up the title
        var cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedTitle.hasPrefix("\"") && cleanedTitle.hasSuffix("\"") {
            cleanedTitle = String(cleanedTitle.dropFirst().dropLast())
        }

        logger.info("Successfully generated title with Ollama Local", category: .transcription)
        return cleanedTitle
    }

    func testConnection() async throws {
        logger.info("Testing Ollama connection...", category: .transcription)

        _ = try await performSummarization(transcript: "This is a test. Say 'Connection successful' if you can read this.")

        logger.info("Ollama connection test successful", category: .transcription)
    }
}

// MARK: - Request/Response Models (Shared with OllamaRemoteService)

// OpenAI-compatible API models
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatCompletionResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message

        struct Message: Codable {
            let content: String?
        }
    }
}

// Native Ollama API models
struct NativeGenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: NativeOptions
}

struct NativeOptions: Codable {
    let temperature: Double
}

struct NativeGenerateResponse: Codable {
    let response: String
}
