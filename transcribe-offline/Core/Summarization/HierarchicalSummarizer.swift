//
//  HierarchicalSummarizer.swift
//  transcribe-offline
//
//  3-pass dynamic summarization: Clean → Condense → Summarize
//

import Foundation

/// 3-pass summarizer using progressive transcript refinement
///
/// Strategy: Clean raw transcript, condense to manageable size, then extract structured summary
/// 1. Pass 1 (Chunked): Clean transcript - remove repetitions, improve coherence
/// 2. Pass 2 (Single): Condense to ~2500 words in prose format
/// 3. Pass 3 (Single): Extract structured markdown summary
///
/// System instructions provide behavioral control at each stage
@MainActor
class HierarchicalSummarizer {
    private let logger = Logger.shared

    // Token budgets for the on-device model's 4096-token context (prompt, instructions and response)

    /// Transcript per cleaning call: the cleaned output is about as long as the input
    private let cleaningChunkTokens = 1500
    /// Transcript per condensing call, alongside a rolling summary of up to ~900 tokens and a 900-token response
    private let condensingChunkTokens = 1400

    /// Result from a single pass
    struct PassResult {
        let passName: String
        let content: String
        let tokensUsed: Int
        let duration: TimeInterval
    }

    /// Complete summarization result
    struct HierarchicalResult {
        let finalSummary: String
        let passes: [PassResult]
        let totalDuration: TimeInterval
        let provider: String
    }

    // MARK: - 3-Pass Dynamic Summarization

    /// 3-pass approach: Clean → Condense → Summarize
    /// - Parameters:
    ///   - transcript: The transcript to summarize
    ///   - provider: The Foundation Models provider
    ///   - speakerCount: Number of speakers (for context-aware summarization)
    func summarizeWithChunks(transcript: String, using provider: FoundationModelsSummarizer, speakerCount: Int? = nil) async throws -> HierarchicalResult {
        let overallStartTime = Date()

        let speakerInfo = speakerCount.map { " with \($0) speakers" } ?? ""
        logger.info("Starting 3-pass summarization: Clean → Condense → Summarize\(speakerInfo)", category: .transcription)

        var allPasses: [PassResult] = []

        // Count initial words
        let initialWordCount = countWords(transcript)
        logger.info("Initial transcript: \(initialWordCount) words", category: .transcription)

        // PASS 1: Clean transcript (chunked if needed)
        let pass1StartTime = Date()
        let cleanedTranscript: String

        let speakerContext = speakerCount.map { "\nThis transcript contains \($0) speakers. Preserve all speaker labels in the format [HH:MM:SS - Speaker N]: text" } ?? ""
        let cleaningSystemInstructions = """
        You are a transcript editor. Your job is to clean and tidy transcripts while preserving ALL content and details. Your output length should match input length. Only remove actual filler words (um, uh, you know) and fix obvious repetitions. Do not paraphrase or condense.\(speakerContext)
        """

        if estimateTokens(transcript) > cleaningChunkTokens {
            logger.info("Pass 1: Transcript too long (~\(estimateTokens(transcript)) tokens), cleaning in chunks", category: .transcription)

            let chunks = chunkTranscript(transcript, maxTokens: cleaningChunkTokens)
            logger.info("Pass 1: Cleaning \(chunks.count) chunks", category: .transcription)

            var cleanedChunks: [String] = []

            for (index, chunk) in chunks.enumerated() {
                logger.info("Pass 1: Chunk \(index + 1)/\(chunks.count): \(countWords(chunk)) words, ~\(estimateTokens(chunk)) tokens", category: .transcription)

                // Cleaning keeps the text, so the output needs about as many tokens as the input
                let cleanedChunk = try await completeSplittingOnOverflow(chunk) { section in
                    let cleanPrompt = """
                    Clean and tidy this section of a meeting transcript (chunk \(index + 1)/\(chunks.count)).

                    Your tasks:
                    1. Make the text more coherent and readable
                    2. Remove weird repetitions and filler words (um, uh, you know, etc.)
                    3. Fix formatting issues
                    4. Preserve ALL names, numbers, dates, details, decisions, and action items
                    5. Keep the natural flow and conversational tone

                    IMPORTANT: Your output should be approximately the SAME LENGTH as the input. Only remove actual filler words and obvious repetitions. Do not paraphrase or shorten complete sentences.

                    DO NOT summarize or condense - just clean and tidy while keeping everything.

                    Transcript section:
                    \(section)
                    """

                    return try await provider.generateCompletion(
                        prompt: cleanPrompt,
                        maxTokens: estimateTokens(section) + 300,
                        temperature: 0.3,
                        instructions: cleaningSystemInstructions
                    )
                }

                cleanedChunks.append(cleanedChunk)
            }

            cleanedTranscript = cleanedChunks.joined(separator: "\n\n")

        } else {
            logger.info("Pass 1: Transcript short (~\(estimateTokens(transcript)) tokens), cleaning in single pass", category: .transcription)

            let cleanPrompt = """
            Clean and tidy this meeting transcript.

            Your tasks:
            1. Make the text more coherent and readable
            2. Remove weird repetitions and filler words (um, uh, you know, etc.)
            3. Fix formatting issues
            4. Preserve ALL names, numbers, dates, details, decisions, and action items
            5. Keep the natural flow and conversational tone

            IMPORTANT: Your output should be approximately the SAME LENGTH as the input. Only remove actual filler words and obvious repetitions. Do not paraphrase or shorten complete sentences.

            DO NOT summarize or condense - just clean and tidy while keeping everything.

            Transcript:
            \(transcript)
            """

            cleanedTranscript = try await provider.generateCompletion(
                prompt: cleanPrompt,
                maxTokens: estimateTokens(transcript) + 300,
                temperature: 0.3,
                instructions: cleaningSystemInstructions
            )
        }

        let pass1Duration = Date().timeIntervalSince(pass1StartTime)
        let cleanedWordCount = countWords(cleanedTranscript)

        let pass1Result = PassResult(
            passName: "Transcript Cleaning",
            content: cleanedTranscript,
            tokensUsed: cleanedTranscript.split(separator: " ").count,
            duration: pass1Duration
        )
        allPasses.append(pass1Result)
        logger.info("✅ Pass 1 complete: Cleaned transcript (\(cleanedWordCount) words)", category: .transcription)

        // PASS 2: Condense to ~2500 words in prose format using rolling summary
        let pass2StartTime = Date()
        let condensedTranscript: String

        let condensingSystemInstructions = """
        You are a transcript condenser. Your job is to progressively build a comprehensive prose summary by incorporating new information from each section. Maintain all important content in natural prose format. Keep specific details, names, numbers, and context.\(speakerContext)
        """

        // If the cleaned transcript does not fit alongside the condensed output, use the rolling summary method
        if estimateTokens(cleanedTranscript) > condensingChunkTokens {
            logger.info("Pass 2: Cleaned transcript too long (~\(estimateTokens(cleanedTranscript)) tokens), using rolling summary method", category: .transcription)

            let chunks = chunkTranscript(cleanedTranscript, maxTokens: condensingChunkTokens)
            logger.info("Pass 2: Processing \(chunks.count) chunks with rolling summary", category: .transcription)

            var rollingSummary = ""

            for (index, chunk) in chunks.enumerated() {
                logger.info("Pass 2: Chunk \(index + 1)/\(chunks.count): ~\(estimateTokens(chunk)) tokens, summary so far ~\(estimateTokens(rollingSummary)) tokens", category: .transcription)

                // A section that still overflows is folded into the summary in smaller pieces
                rollingSummary = try await foldSplittingOnOverflow(chunk, into: rollingSummary) { section, summary in
                    let rollingPrompt: String
                    if summary.isEmpty {
                        // First chunk: Create initial summary
                        rollingPrompt = """
                        This is the first section of a longer meeting transcript (section \(index + 1)/\(chunks.count)).

                        Create a prose summary of this section (~400-600 words). Focus on:
                        - Key topics and discussions
                        - Specific details: names, numbers, dates, organizations
                        - Decisions and action items
                        - Important context

                        Keep in natural prose/paragraph format (NOT bullet points).

                        Section \(index + 1) (~\(countWords(section)) words):
                        \(section)
                        """
                    } else {
                        // Subsequent chunks: Update rolling summary
                        rollingPrompt = """
                        You have a running summary of a meeting transcript. Now incorporate information from the next section.

                        This is section \(index + 1) of \(chunks.count).

                        Your task:
                        1. Read the current summary and the new section
                        2. Integrate new information from the section into the summary
                        3. Maintain chronological flow
                        4. Keep all specific details from both the summary and new section
                        5. Remove redundancy (if new section repeats what's already summarized, don't duplicate)
                        6. Keep the updated summary around 400-600 words

                        Keep in natural prose/paragraph format (NOT bullet points).

                        Current summary (~\(countWords(summary)) words):
                        \(summary)

                        New section \(index + 1) (~\(countWords(section)) words):
                        \(section)
                        """
                    }

                    return try await provider.generateCompletion(
                        prompt: rollingPrompt,
                        maxTokens: 900,
                        temperature: 0.4,
                        instructions: condensingSystemInstructions
                    )
                }
            }

            condensedTranscript = rollingSummary

        } else {
            // Short enough to condense in single pass
            logger.info("Pass 2: Condensing transcript from \(cleanedWordCount) to ~2500 words in single pass", category: .transcription)

            let condensePrompt = """
            Condense this cleaned meeting transcript to approximately 2500 words maximum.

            Requirements:
            - Keep in full prose/paragraph format (NOT bullet points)
            - Preserve ALL specific details: names, numbers, dates, organizations, decisions, action items
            - Maintain chronological flow and natural narrative
            - Remove redundancy and verbose explanations
            - Keep the conversational essence

            Current word count: \(cleanedWordCount) words
            Target: ~2500 words

            Cleaned transcript:
            \(cleanedTranscript)
            """

            condensedTranscript = try await provider.generateCompletion(
                prompt: condensePrompt,
                maxTokens: 1500,  // Reduced from 3000 to stay within 4096 token limit for 3000-word cleaned transcripts
                temperature: 0.4,
                instructions: condensingSystemInstructions
            )
        }

        let pass2Duration = Date().timeIntervalSince(pass2StartTime)
        let condensedWordCount = countWords(condensedTranscript)

        let pass2Result = PassResult(
            passName: "Prose Condensation",
            content: condensedTranscript,
            tokensUsed: condensedTranscript.split(separator: " ").count,
            duration: pass2Duration
        )
        allPasses.append(pass2Result)
        logger.info("✅ Pass 2 complete: Condensed to \(condensedWordCount) words", category: .transcription)

        // PASS 3: Extract structured summary
        let pass3StartTime = Date()

        let speakerAwareInstructions = speakerCount.map { count in
            count > 1 ? "\nThis is a \(count)-person conversation. Attribute key points, decisions, and action items to specific speakers when possible." : ""
        } ?? ""

        let summarySystemInstructions = """
        You are a precise meeting minutes assistant. Extract key information into a structured summary format. Always use specific names, numbers, and details from the source material. Never generalize entities into categories.\(speakerAwareInstructions)
        """

        let participantsSection = speakerCount.map { count in
            count > 1 ? """

            ## Participants
            Briefly describe each speaker's main role/topics in the conversation.
            - Speaker 1: [Key topics they discussed]
            - Speaker 2: [Key topics they discussed]
            """ : ""
        } ?? ""

        let speakerAttributionGuidelines = speakerCount.map { count in
            count > 1 ? """

            **Speaker Attribution:**
            - When summarizing key points, attribute them to speakers: "Speaker 1 suggested...", "Speaker 2 agreed that..."
            - For action items: "Speaker 1 to complete X by Friday"
            - For decisions: "Agreed by Speaker 2, proposed by Speaker 1"
            """ : ""
        } ?? ""

        let summaryPrompt = """
        Create a structured summary from this condensed transcript.

        Condensed transcript:
        \(condensedTranscript)

        Create a polished markdown summary with this structure:

        # [Title - 5-10 words]

        ## Overview
        A single paragraph (3-5 sentences) summarizing the purpose, key participants, main topics, and primary outcomes. Include specific names and numbers where relevant.\(participantsSection)

        ## Topics Discussed
        Organize content by topic using ### headings. Create as many topics as needed (could be 1, could be 50).

        For each topic:
        ### [Topic Name]
        - Main points with specific details (names, numbers, dates, organizations)
        - Use sub-bullets (  - ) for supporting details when needed
        - Use #### for sub-topics if a topic has distinct sections

        ## Decisions
        - List specific decisions made
        (ONLY include if decisions exist; skip entirely if none)

        ## Actions
        - List action items, open questions, next steps
        (ONLY include if actions exist; skip entirely if none)

        Guidelines:
        - Use SPECIFIC details from the transcript (names, numbers, exact entities)
        - Eliminate redundancy
        - Organize logically by topic\(speakerAttributionGuidelines)
        """

        logger.info("Pass 3: Extracting structured summary", category: .transcription)

        let finalSummary = try await provider.generateCompletion(
            prompt: summaryPrompt,
            maxTokens: 1200,
            temperature: 0.6,
            instructions: summarySystemInstructions
        )

        let pass3Duration = Date().timeIntervalSince(pass3StartTime)

        let pass3Result = PassResult(
            passName: "Structured Summary Extraction",
            content: finalSummary,
            tokensUsed: finalSummary.split(separator: " ").count,
            duration: pass3Duration
        )
        allPasses.append(pass3Result)
        logger.info("✅ Pass 3 complete: Structured summary extracted", category: .transcription)

        let totalDuration = Date().timeIntervalSince(overallStartTime)

        logger.info("✅ 3-pass summarization complete in \(String(format: "%.2f", totalDuration))s", category: .transcription)
        logger.info("   Word progression: \(initialWordCount) → \(cleanedWordCount) → \(condensedWordCount) → summary", category: .transcription)

        return HierarchicalResult(
            finalSummary: finalSummary,
            passes: allPasses,
            totalDuration: totalDuration,
            provider: provider.displayName
        )
    }

    // MARK: - Helper Functions

    /// Count words in a text string
    private func countWords(_ text: String) -> Int {
        return text.split(separator: " ").count
    }

    /// Estimate token count from text. Based on UTF-8 size rather than words: a per-word estimate
    /// holds for plain English but undercounts other languages, accents, numbers and speaker labels.
    private func estimateTokens(_ text: String) -> Int {
        return text.utf8.count / 3
    }

    /// Split transcript into chunks of at most `maxTokens` (estimated), breaking between
    /// speaker turns where possible so each chunk starts with a speaker label
    private func chunkTranscript(_ transcript: String, maxTokens: Int) -> [String] {
        // Turns longer than a chunk are broken up between words
        var pieces: [String] = []
        for turn in transcript.components(separatedBy: "\n\n") where !turn.isEmpty {
            if estimateTokens(turn) <= maxTokens {
                pieces.append(turn)
                continue
            }
            var current: [Substring] = []
            for word in turn.split(separator: " ") {
                if !current.isEmpty && estimateTokens(current.joined(separator: " ") + " " + word) > maxTokens {
                    pieces.append(current.joined(separator: " "))
                    current.removeAll()
                }
                current.append(word)
            }
            if !current.isEmpty {
                pieces.append(current.joined(separator: " "))
            }
        }

        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : current + "\n\n" + piece
            if !current.isEmpty && estimateTokens(candidate) > maxTokens {
                chunks.append(current)
                current = piece
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    /// Whether an error is the model reporting that the prompt and response do not fit its context window
    private func isContextOverflow(_ error: Error) -> Bool {
        return error.localizedDescription.lowercased().contains("context window")
    }

    /// Split text into two halves of similar size, between speaker turns where possible
    private func halves(of text: String) -> (String, String)? {
        let chunks = chunkTranscript(text, maxTokens: max(1, estimateTokens(text) / 2 + 1))
        guard chunks.count >= 2 else { return nil }
        let middle = chunks.count / 2
        return (chunks[..<middle].joined(separator: "\n\n"), chunks[middle...].joined(separator: "\n\n"))
    }

    /// Run a text-to-text step, splitting the text in half and joining the results if it does not fit.
    /// The token estimate is approximate, so the model's own overflow error is the final check.
    private func completeSplittingOnOverflow(_ text: String, _ step: (String) async throws -> String) async throws -> String {
        do {
            return try await step(text)
        } catch where isContextOverflow(error) {
            guard let (first, second) = halves(of: text) else { throw error }
            logger.warning("Section (~\(estimateTokens(text)) tokens) exceeded the context window, splitting it in two", category: .transcription)
            let firstResult = try await completeSplittingOnOverflow(first, step)
            let secondResult = try await completeSplittingOnOverflow(second, step)
            return firstResult + "\n\n" + secondResult
        }
    }

    /// Fold a section into a rolling summary, folding it in two halves if it does not fit
    private func foldSplittingOnOverflow(_ section: String, into summary: String, _ step: (String, String) async throws -> String) async throws -> String {
        do {
            return try await step(section, summary)
        } catch where isContextOverflow(error) {
            guard let (first, second) = halves(of: section) else { throw error }
            logger.warning("Section (~\(estimateTokens(section)) tokens) exceeded the context window, splitting it in two", category: .transcription)
            let withFirst = try await foldSplittingOnOverflow(first, into: summary, step)
            return try await foldSplittingOnOverflow(second, into: withFirst, step)
        }
    }
}
