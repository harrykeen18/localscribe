import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarization provider using Apple's Foundation Models framework (macOS 26+, Apple Silicon)
@MainActor
class FoundationModelsSummarizer: SummarizationProvider {
    private let logger = Logger.shared

    var providerName: String { "foundationModels" }
    var displayName: String { "Apple Intelligence" }

    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    private var isFoundationModelsAvailable: Bool {
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            return model.isAvailable
        }
        return false
    }
    #else
    private var isFoundationModelsAvailable: Bool { false }
    #endif

    func isAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let available = isFoundationModelsAvailable
            if available {
                logger.info("Foundation Models available", category: .transcription)
            } else {
                logger.info("Foundation Models not available (check Apple Intelligence settings)", category: .transcription)
            }
            return available
        }
        #endif

        logger.info("Foundation Models not available (requires macOS 26+)", category: .transcription)
        return false
    }

    func testConnection() async throws {
        guard await isAvailable() else {
            throw SummarizationError.providerNotAvailable("Foundation Models requires macOS 26+ with Apple Intelligence enabled. If this error seems incorrect, try restarting your Mac.")
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Try a simple test prompt
            let session = LanguageModelSession()
            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.5,
                maximumResponseTokens: 50
            )

            _ = try await session.respond(to: "Say 'ok'", options: options)
            logger.info("Foundation Models test successful", category: .transcription)
        }
        #endif
    }

    func summarize(transcript: String) async throws -> SummaryResult {
        let startTime = Date()

        guard await isAvailable() else {
            throw SummarizationError.providerNotAvailable("Foundation Models is not available")
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            logger.info("Starting summarization with Foundation Models", category: .transcription)

            let session = LanguageModelSession()

            // Craft a detailed prompt for summarization
            let prompt = """
            Please analyze the following meeting or conversation transcript and create a structured summary in markdown format.

            Format your response as follows:

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

            Transcript:
            \(transcript)
            """

            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.7,
                maximumResponseTokens: 500
            )

            do {
                let response = try await session.respond(to: prompt, options: options)
                let processingTime = Date().timeIntervalSince(startTime)

                logger.info("Foundation Models summarization completed in \(String(format: "%.2f", processingTime))s", category: .transcription)

                // Extract the content from the response
                let responseText = response.content

                return SummaryResult(
                    markdown: responseText,
                    timestamp: Date(),
                    processingTime: processingTime,
                    provider: displayName
                )
            } catch {
                // Parse the error to provide better diagnostics
                let errorDescription = error.localizedDescription

                // Check for safety guardrail triggers
                if errorDescription.contains("Safety guardrails") || errorDescription.contains("unsafe") {
                    logger.warning("Foundation Models safety guardrails triggered - transcript may contain flagged content", category: .transcription)
                    throw SummarizationError.responseError("Apple Intelligence safety filters blocked this content. If this error seems incorrect, try restarting your Mac.")
                }

                // Check for missing system assets (corrupted installation)
                if errorDescription.contains("metadata.json") || errorDescription.contains("No such file") {
                    logger.error("Foundation Models system assets missing - Apple Intelligence may need reinstallation", category: .transcription)
                    throw SummarizationError.responseError("Apple Intelligence system files are missing or corrupted. Try:\n1. Restart your Mac\n2. Check System Settings > Apple Intelligence")
                }

                // Check for inference failures
                if errorDescription.contains("InferenceError") || errorDescription.contains("inferenceFailed") {
                    logger.error("Foundation Models inference failed: \(errorDescription)", category: .transcription)
                    throw SummarizationError.responseError("Apple Intelligence inference failed. The model may be unavailable. If this error seems incorrect, try restarting your Mac.")
                }

                // Generic error
                logger.error("Foundation Models summarization failed: \(errorDescription)", category: .transcription)
                throw SummarizationError.responseError(errorDescription)
            }
        }
        #endif

        throw SummarizationError.providerNotAvailable("Foundation Models requires macOS 26+. If this error seems incorrect, try restarting your Mac.")
    }

    /// Generate a completion with custom parameters (for hierarchical summarization)
    func generateCompletion(prompt: String, maxTokens: Int = 500, temperature: Double = 0.7, instructions: String? = nil) async throws -> String {
        guard await isAvailable() else {
            throw SummarizationError.providerNotAvailable("Foundation Models is not available")
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Create session with optional instructions (system prompt)
            let session: LanguageModelSession
            if let instructions = instructions {
                session = LanguageModelSession(instructions: instructions)
            } else {
                session = LanguageModelSession()
            }

            let options = GenerationOptions(
                sampling: .greedy,
                temperature: temperature,
                maximumResponseTokens: maxTokens
            )

            do {
                let response = try await session.respond(to: prompt, options: options)
                return response.content
            } catch {
                let errorDescription = error.localizedDescription

                // Check for safety guardrail triggers
                if errorDescription.contains("Safety guardrails") || errorDescription.contains("unsafe") {
                    throw SummarizationError.responseError("Apple Intelligence safety filters blocked this content.")
                }

                // Check for missing system assets
                if errorDescription.contains("metadata.json") || errorDescription.contains("No such file") {
                    throw SummarizationError.responseError("Apple Intelligence system files are missing or corrupted.")
                }

                // Check for inference failures
                if errorDescription.contains("InferenceError") || errorDescription.contains("inferenceFailed") {
                    throw SummarizationError.responseError("Apple Intelligence inference failed.")
                }

                throw SummarizationError.responseError(errorDescription)
            }
        }
        #endif

        throw SummarizationError.providerNotAvailable("Foundation Models requires macOS 26+")
    }

    func generateTitle(from summary: String) async throws -> String {
        let startTime = Date()

        guard await isAvailable() else {
            throw SummarizationError.providerNotAvailable("Foundation Models is not available")
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            logger.info("Generating title with Foundation Models", category: .transcription)

            let session = LanguageModelSession()

            let prompt = """
            Based on the following meeting summary, generate a concise, descriptive title (5-10 words maximum).
            The title should capture the main topic or purpose of the meeting.
            Respond with ONLY the title text, no quotes, no extra formatting.

            Summary:
            \(summary)
            """

            let options = GenerationOptions(
                sampling: .greedy,
                temperature: 0.3,
                maximumResponseTokens: 30
            )

            do {
                let response = try await session.respond(to: prompt, options: options)
                let processingTime = Date().timeIntervalSince(startTime)

                logger.info("Foundation Models title generation completed in \(String(format: "%.2f", processingTime))s", category: .transcription)

                let title = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Remove quotes if the model added them
                var cleanedTitle = title
                if cleanedTitle.hasPrefix("\"") && cleanedTitle.hasSuffix("\"") {
                    cleanedTitle = String(cleanedTitle.dropFirst().dropLast())
                }

                return cleanedTitle
            } catch {
                logger.error("Foundation Models title generation failed: \(error.localizedDescription)", category: .transcription)
                throw SummarizationError.responseError("Failed to generate title: \(error.localizedDescription)")
            }
        }
        #endif

        throw SummarizationError.providerNotAvailable("Foundation Models requires macOS 26+")
    }
}
