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
    func summarizeWithChunks(transcript: String, using provider: FoundationModelsSummarizer) async throws -> HierarchicalResult {
        let overallStartTime = Date()

        logger.info("Starting 3-pass summarization: Clean → Condense → Summarize", category: .transcription)

        var allPasses: [PassResult] = []

        // Count initial words
        let initialWordCount = countWords(transcript)
        logger.info("Initial transcript: \(initialWordCount) words", category: .transcription)

        // PASS 1: Clean transcript (chunked if needed)
        let pass1StartTime = Date()
        let cleanedTranscript: String

        let cleaningSystemInstructions = """
        You are a transcript editor. Your job is to clean and tidy meeting transcripts while preserving ALL content and details. Your output length should match input length. Only remove actual filler words (um, uh, you know) and fix obvious repetitions. Do not paraphrase or condense.
        """

        if initialWordCount > 2000 {
            logger.info("Pass 1: Transcript too long (\(initialWordCount) words), cleaning in chunks", category: .transcription)

            let chunks = chunkTranscript(transcript, chunkSize: 1200, overlap: 200)
            logger.info("Pass 1: Cleaning \(chunks.count) chunks", category: .transcription)

            var cleanedChunks: [String] = []

            for (index, chunk) in chunks.enumerated() {
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
                \(chunk)
                """

                // Calculate token budget for diagnostics
                let chunkWordCount = countWords(chunk)
                let chunkTokens = estimateTokens(chunk)
                let promptTokens = estimateTokens(cleanPrompt) - chunkTokens  // Prompt overhead only
                let instructionsTokens = estimateTokens(cleaningSystemInstructions)
                let outputTokens = 1600
                let totalTokens = chunkTokens + promptTokens + instructionsTokens + outputTokens

                logger.info("Pass 1: Chunk \(index + 1)/\(chunks.count) token analysis:", category: .transcription)
                logger.info("  - Chunk: \(chunkWordCount) words, ~\(chunkTokens) tokens", category: .transcription)
                logger.info("  - Prompt overhead: ~\(promptTokens) tokens", category: .transcription)
                logger.info("  - Instructions: ~\(instructionsTokens) tokens", category: .transcription)
                logger.info("  - Output allowance: \(outputTokens) tokens", category: .transcription)
                logger.info("  - TOTAL ESTIMATE: ~\(totalTokens) tokens (limit: 4096)", category: .transcription)

                if totalTokens > 4096 {
                    logger.warning("  ⚠️ Chunk \(index + 1) EXCEEDS context window by ~\(totalTokens - 4096) tokens!", category: .transcription)
                }

                let cleanedChunk = try await provider.generateCompletion(
                    prompt: cleanPrompt,
                    maxTokens: 1600,
                    temperature: 0.3,
                    instructions: cleaningSystemInstructions
                )

                cleanedChunks.append(cleanedChunk)
            }

            cleanedTranscript = cleanedChunks.joined(separator: "\n\n")

        } else {
            logger.info("Pass 1: Transcript short (\(initialWordCount) words), cleaning in single pass", category: .transcription)

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
                maxTokens: 1600,  // Reduced from 3000 to stay within 4096 token limit
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
        You are a meeting transcript condenser. Your job is to progressively build a comprehensive prose summary by incorporating new information from each section. Maintain all important content in natural prose format. Keep specific details, names, numbers, and context.
        """

        // If cleaned transcript is too long (>3000 words), use rolling summary method
        if cleanedWordCount > 3000 {
            logger.info("Pass 2: Cleaned transcript too long (\(cleanedWordCount) words), using rolling summary method", category: .transcription)

            let chunks = chunkTranscript(cleanedTranscript, chunkSize: 1200, overlap: 200)
            logger.info("Pass 2: Processing \(chunks.count) chunks with rolling summary", category: .transcription)

            var rollingSummary = ""

            for (index, chunk) in chunks.enumerated() {
                let chunkWordCount = countWords(chunk)
                let currentSummaryWordCount = countWords(rollingSummary)

                let rollingPrompt: String
                if index == 0 {
                    // First chunk: Create initial summary
                    rollingPrompt = """
                    This is the first section of a longer meeting transcript (section 1/\(chunks.count)).

                    Create a prose summary of this section (~500-800 words). Focus on:
                    - Key topics and discussions
                    - Specific details: names, numbers, dates, organizations
                    - Decisions and action items
                    - Important context

                    Keep in natural prose/paragraph format (NOT bullet points).

                    Section 1 (~\(chunkWordCount) words):
                    \(chunk)
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
                    6. Keep the updated summary around 500-800 words (can grow slightly as you add sections)

                    Keep in natural prose/paragraph format (NOT bullet points).

                    Current summary (~\(currentSummaryWordCount) words):
                    \(rollingSummary)

                    New section \(index + 1) (~\(chunkWordCount) words):
                    \(chunk)
                    """
                }

                // Calculate token budget for diagnostics
                let chunkTokens = estimateTokens(chunk)
                let promptTokens = estimateTokens(rollingPrompt) - chunkTokens - (index == 0 ? 0 : estimateTokens(rollingSummary))  // Overhead only
                let instructionsTokens = estimateTokens(condensingSystemInstructions)
                let outputTokens = 1000

                let totalTokens: Int
                if index == 0 {
                    // First chunk: no rolling summary yet
                    totalTokens = chunkTokens + promptTokens + instructionsTokens + outputTokens
                    logger.info("Pass 2: Chunk \(index + 1)/\(chunks.count) token analysis:", category: .transcription)
                    logger.info("  - New section: \(chunkWordCount) words, ~\(chunkTokens) tokens", category: .transcription)
                } else {
                    // Subsequent chunks: include rolling summary
                    let summaryTokens = estimateTokens(rollingSummary)
                    totalTokens = summaryTokens + chunkTokens + promptTokens + instructionsTokens + outputTokens
                    logger.info("Pass 2: Chunk \(index + 1)/\(chunks.count) token analysis:", category: .transcription)
                    logger.info("  - Current summary: \(currentSummaryWordCount) words, ~\(summaryTokens) tokens", category: .transcription)
                    logger.info("  - New section: \(chunkWordCount) words, ~\(chunkTokens) tokens", category: .transcription)
                }

                logger.info("  - Prompt overhead: ~\(promptTokens) tokens", category: .transcription)
                logger.info("  - Instructions: ~\(instructionsTokens) tokens", category: .transcription)
                logger.info("  - Output allowance: \(outputTokens) tokens", category: .transcription)
                logger.info("  - TOTAL ESTIMATE: ~\(totalTokens) tokens (limit: 4096)", category: .transcription)

                if totalTokens > 4096 {
                    logger.warning("  ⚠️ Chunk \(index + 1) EXCEEDS context window by ~\(totalTokens - 4096) tokens!", category: .transcription)
                }

                rollingSummary = try await provider.generateCompletion(
                    prompt: rollingPrompt,
                    maxTokens: 1000,  // Allow room for growing summary
                    temperature: 0.4,
                    instructions: condensingSystemInstructions
                )
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

        let summarySystemInstructions = """
        You are a precise meeting minutes assistant. Extract key information into a structured summary format. Always use specific names, numbers, and details from the source material. Never generalize entities into categories.
        """

        let summaryPrompt = """
        Create a structured summary from this condensed transcript.

        Condensed transcript:
        \(condensedTranscript)

        Create a polished markdown summary with this structure:

        # [Meeting Title - 5-10 words]

        ## Overview
        A single paragraph (3-5 sentences) summarizing the meeting's purpose, key participants, main topics, and primary outcomes. Include specific names and numbers where relevant.

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
        - Organize logically by topic
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

    /// Estimate token count from text (rough approximation: 1.33 tokens per word)
    private func estimateTokens(_ text: String) -> Int {
        let wordCount = countWords(text)
        return Int(Double(wordCount) * 1.33)
    }

    /// Split transcript into overlapping chunks
    private func chunkTranscript(_ transcript: String, chunkSize: Int, overlap: Int) -> [String] {
        let allWords = transcript.split(separator: " ")
        let totalWords = allWords.count

        guard totalWords > chunkSize else {
            return [transcript]
        }

        var chunks: [String] = []
        var startIndex = 0

        while startIndex < totalWords {
            let endIndex = min(startIndex + chunkSize, totalWords)
            let chunk = allWords[startIndex..<endIndex].joined(separator: " ")
            chunks.append(chunk)

            startIndex += (chunkSize - overlap)

            if endIndex == totalWords {
                break
            }
        }

        return chunks
    }
}
