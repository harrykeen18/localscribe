import Foundation
import Combine

/// Manages multiple summarization providers and selects the best available one
@MainActor
class SummarizationManager: ObservableObject {
    static let shared = SummarizationManager()

    private let logger = Logger.shared
    private let chunker = TranscriptChunker()
    private let hierarchicalSummarizer = HierarchicalSummarizer()

    // All available providers
    private var providers: [SummarizationProvider] = []

    // Currently selected provider (for manual override)
    @Published var selectedProviderType: SummarizationProviderType?

    // Enable hierarchical summarization (6-pass approach for better quality)
    @Published var useHierarchicalSummarization: Bool = true

    private init() {
        logger.info("SummarizationManager initialized", category: .transcription)
        registerProviders()
    }

    // MARK: - Provider Registration

    private func registerProviders() {
        // Register all available providers
        providers = [
            FoundationModelsSummarizer(),
            OllamaLocalService.shared,
            OllamaRemoteService.shared
        ]

        logger.info("Registered \(providers.count) summarization providers", category: .transcription)
    }

    // MARK: - Provider Selection

    /// Get the best available provider based on priority
    /// Priority: 1) Local Ollama (secure), 2) Foundation Models (secure), 3) Remote Ollama (requires consent)
    /// If a provider is manually selected, ONLY that provider is used (no fallback to auto-selection)
    func getBestProvider() async -> SummarizationProvider? {
        // If user has manually selected a provider, ONLY use that provider
        if let selectedType = selectedProviderType {
            if let provider = getProviderByType(selectedType), await provider.isAvailable() {
                logger.info("Using manually selected provider: \(provider.displayName)", category: .transcription)
                return provider
            } else {
                // User explicitly selected this provider, but it's not available
                // Do NOT fall back to auto-selection - respect user's choice
                logger.warning("Manually selected provider '\(selectedType.displayName)' is not available", category: .transcription)
                return nil
            }
        }

        // Auto mode: Try providers in priority order with fallback
        logger.info("Auto mode: trying providers in priority order", category: .transcription)

        // Try Local Ollama first (secure, user-configured)
        if let ollamaLocal = providers.first(where: { $0.providerName == "ollamaLocal" }),
           await ollamaLocal.isAvailable() {
            logger.info("Using Ollama (Local/LAN)", category: .transcription)
            return ollamaLocal
        }

        // Try Foundation Models next (secure, private, local, free)
        if let foundationModels = providers.first(where: { $0.providerName == "foundationModels" }),
           await foundationModels.isAvailable() {
            logger.info("Using Foundation Models (Apple Intelligence)", category: .transcription)
            return foundationModels
        }

        // Try Remote Ollama last (less secure, requires user consent)
        if let ollamaRemote = providers.first(where: { $0.providerName == "ollamaRemote" }),
           await ollamaRemote.isAvailable() {
            logger.info("Using Ollama (Remote/Custom)", category: .transcription)
            return ollamaRemote
        }

        logger.warning("No summarization providers available", category: .transcription)
        return nil
    }

    /// Get provider by type
    func getProviderByType(_ type: SummarizationProviderType) -> SummarizationProvider? {
        return providers.first { $0.providerName == type.rawValue }
    }

    /// Get all registered providers
    func getAllProviders() -> [SummarizationProvider] {
        return providers
    }

    /// Check availability of all providers
    func checkAllProviders() async -> [String: Bool] {
        var availability: [String: Bool] = [:]

        for provider in providers {
            let isAvailable = await provider.isAvailable()
            availability[provider.providerName] = isAvailable
            logger.debug("Provider '\(provider.displayName)': \(isAvailable ? "available" : "not available")", category: .transcription)
        }

        return availability
    }

    // MARK: - Summarization

    /// Summarize using the best available provider
    func summarize(transcript: String) async throws -> SummaryResult {
        guard let provider = await getBestProvider() else {
            // Provide different error messages for manual vs auto mode
            if let selectedType = selectedProviderType {
                logger.error("Manually selected provider '\(selectedType.displayName)' is not available", category: .transcription)
                throw SummarizationError.providerNotAvailable("'\(selectedType.displayName)' is not available. Please check your configuration in Settings or switch to Auto mode.")
            } else {
                logger.error("No summarization providers available in Auto mode", category: .transcription)
                throw SummarizationError.noProvidersAvailable
            }
        }

        logger.info("Summarizing with provider: \(provider.displayName)", category: .transcription)

        // Check if we should use 3-pass summarization with system instructions for Foundation Models
        if useHierarchicalSummarization,
           let foundationModels = provider as? FoundationModelsSummarizer {
            logger.info("Using 3-pass summarization: Clean → Condense → Summarize", category: .transcription)
            do {
                let hierarchicalResult = try await hierarchicalSummarizer.summarizeWithChunks(transcript: transcript, using: foundationModels)
                logger.info("3-pass summarization successful: \(hierarchicalResult.passes.count) passes in \(String(format: "%.2f", hierarchicalResult.totalDuration))s", category: .transcription)

                return SummaryResult(
                    markdown: hierarchicalResult.finalSummary,
                    timestamp: Date(),
                    processingTime: hierarchicalResult.totalDuration,
                    provider: "\(hierarchicalResult.provider) (3-pass)"
                )
            } catch {
                // Check if error is due to context window limit
                if isContextWindowError(error) {
                    logger.warning("3-pass summarization exceeded context window, falling back to traditional chunking...", category: .transcription)
                    return try await summarizeWithChunking(transcript: transcript, provider: provider)
                } else {
                    logger.error("3-pass summarization failed: \(error.localizedDescription)", category: .transcription)
                    throw error
                }
            }
        }

        do {
            // Use standard single-pass summarization
            let result = try await provider.summarize(transcript: transcript)
            logger.info("Summarization successful with \(provider.displayName)", category: .transcription)
            return result
        } catch {
            // Check if error is due to context window limit
            if isContextWindowError(error) {
                logger.warning("Context window exceeded, retrying with chunking...", category: .transcription)
                return try await summarizeWithChunking(transcript: transcript, provider: provider)
            } else {
                logger.error("Summarization failed with \(provider.displayName): \(error.localizedDescription)", category: .transcription)
                throw error
            }
        }
    }

    /// Summarize using a specific provider
    func summarize(transcript: String, using providerType: SummarizationProviderType) async throws -> SummaryResult {
        guard let provider = getProviderByType(providerType) else {
            throw SummarizationError.providerNotAvailable("Provider '\(providerType.displayName)' not found")
        }

        guard await provider.isAvailable() else {
            throw SummarizationError.providerNotAvailable("Provider '\(providerType.displayName)' is not available")
        }

        logger.info("Summarizing with specific provider: \(provider.displayName)", category: .transcription)

        return try await provider.summarize(transcript: transcript)
    }

    // MARK: - Title Generation

    /// Generate a title from a summary using the best available provider
    func generateTitle(from summary: String) async throws -> String {
        guard let provider = await getBestProvider() else {
            // Provide different error messages for manual vs auto mode
            if let selectedType = selectedProviderType {
                logger.error("Manually selected provider '\(selectedType.displayName)' is not available for title generation", category: .transcription)
                throw SummarizationError.providerNotAvailable("'\(selectedType.displayName)' is not available")
            } else {
                logger.error("No summarization providers available for title generation", category: .transcription)
                throw SummarizationError.noProvidersAvailable
            }
        }

        logger.info("Generating title with provider: \(provider.displayName)", category: .transcription)

        do {
            let title = try await provider.generateTitle(from: summary)
            logger.info("Title generation successful with \(provider.displayName)", category: .transcription)
            return title
        } catch {
            logger.error("Title generation failed with \(provider.displayName): \(error.localizedDescription)", category: .transcription)
            throw error
        }
    }

    // MARK: - Testing

    /// Test a specific provider
    func testProvider(_ providerType: SummarizationProviderType) async throws {
        guard let provider = getProviderByType(providerType) else {
            throw SummarizationError.providerNotAvailable("Provider '\(providerType.displayName)' not found")
        }

        try await provider.testConnection()
    }

    // MARK: - Chunking Support

    /// Check if error is related to context window/token limit
    private func isContextWindowError(_ error: Error) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()

        let contextWindowKeywords = [
            "context",
            "window",
            "token",
            "length",
            "too long",
            "exceeded",
            "limit",
            "maximum",
            "too large"
        ]

        return contextWindowKeywords.contains { keyword in
            errorMessage.contains(keyword)
        }
    }

    /// Summarize a long transcript by chunking it
    private func summarizeWithChunking(transcript: String, provider: SummarizationProvider) async throws -> SummaryResult {
        let startTime = Date()

        logger.info("Starting chunked summarization", category: .transcription)

        // Split transcript into chunks
        let chunkResult = chunker.chunkTranscript(transcript, maxWords: 2000, overlapWords: 200)

        logger.info("Processing \(chunkResult.totalChunks) chunks...", category: .transcription)

        // Summarize each chunk
        var chunkSummaries: [String] = []

        for (index, chunk) in chunkResult.chunks.enumerated() {
            logger.info("Summarizing chunk \(index + 1)/\(chunkResult.totalChunks)...", category: .transcription)

            // Create chunk-specific prompt
            let chunkPrompt = createChunkPrompt(chunk: chunk, chunkNumber: index + 1, totalChunks: chunkResult.totalChunks)

            do {
                let chunkResult = try await provider.summarize(transcript: chunkPrompt)
                chunkSummaries.append(chunkResult.markdown)
                logger.info("Chunk \(index + 1) summarized successfully", category: .transcription)
            } catch {
                logger.error("Failed to summarize chunk \(index + 1): \(error.localizedDescription)", category: .transcription)
                throw SummarizationError.apiError("Chunking failed at chunk \(index + 1)/\(chunkResult.totalChunks): \(error.localizedDescription)")
            }
        }

        // Combine summaries for meta-pass
        logger.info("Combining \(chunkSummaries.count) chunk summaries...", category: .transcription)
        let combinedSummaries = chunker.combineSummariesForMetaPass(chunkSummaries: chunkSummaries)

        // Meta-summarization: combine all chunk summaries into one
        let metaPrompt = createMetaSummaryPrompt(combinedSummaries: combinedSummaries, totalChunks: chunkResult.totalChunks)

        do {
            let finalResult = try await provider.summarize(transcript: metaPrompt)
            let duration = Date().timeIntervalSince(startTime)

            logger.info("Chunked summarization completed in \(String(format: "%.2f", duration))s", category: .transcription)

            // Add note that this was processed in chunks
            let annotatedMarkdown = """
            \(finalResult.markdown)

            ---
            📝 *Large transcript processed in \(chunkResult.totalChunks) chunks for complete coverage*
            """

            return SummaryResult(
                markdown: annotatedMarkdown,
                model: finalResult.model,
                timestamp: Date(),
                processingTime: duration,
                provider: provider.displayName
            )
        } catch {
            logger.error("Meta-summarization failed: \(error.localizedDescription)", category: .transcription)
            throw SummarizationError.apiError("Failed to combine chunk summaries: \(error.localizedDescription)")
        }
    }

    /// Create prompt for individual chunk summarization
    private func createChunkPrompt(chunk: String, chunkNumber: Int, totalChunks: Int) -> String {
        return """
        This is chunk \(chunkNumber) of \(totalChunks) from a longer transcript. Extract the key information from this section.

        Focus on:
        - Main topics discussed in this section
        - Key points and decisions
        - Action items mentioned
        - Important details (names, dates, numbers)

        \(chunk)
        """
    }

    /// Create prompt for meta-summarization (combining chunk summaries)
    private func createMetaSummaryPrompt(combinedSummaries: String, totalChunks: Int) -> String {
        return """
        You are combining \(totalChunks) individual summaries from different sections of a long transcript into one cohesive summary.

        Create a well-structured, unified Markdown summary that:

        # [Brief Title Based on Overall Content]

        ## Overview
        [2-3 sentence summary of the entire conversation/meeting]

        ## Key Points
        - [Main point 1]
        - [Main point 2]
        - [Main point 3]
        (Consolidate duplicate points across chunks)

        ## Details
        [Expanded discussion, organized by topic]

        ## Action Items
        - [ ] [Action item 1]
        - [ ] [Action item 2]
        (Combine all action items from all chunks)

        ## References
        - [Any URLs, names, or resources mentioned]

        Here are the individual chunk summaries to combine:

        \(combinedSummaries)
        """
    }
}
