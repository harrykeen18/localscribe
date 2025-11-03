import Foundation

/// Utility for splitting long transcripts into manageable chunks for summarization
struct TranscriptChunker {

    /// Result of chunking operation
    struct ChunkResult {
        let chunks: [String]
        let totalChunks: Int
        let wordsPerChunk: Int
        let overlapWords: Int
    }

    private let logger = Logger.shared

    /// Split transcript into overlapping chunks
    /// - Parameters:
    ///   - transcript: Full transcript text to chunk
    ///   - maxWords: Maximum words per chunk (default: 2000)
    ///   - overlapWords: Number of words to overlap between chunks (default: 200)
    /// - Returns: ChunkResult containing the chunks and metadata
    func chunkTranscript(_ transcript: String, maxWords: Int = 2000, overlapWords: Int = 200) -> ChunkResult {
        logger.info("Chunking transcript with maxWords=\(maxWords), overlap=\(overlapWords)", category: .transcription)

        // Split into words while preserving whitespace information
        let words = transcript.split(separator: " ", omittingEmptySubsequences: false)
        let totalWords = words.count

        guard totalWords > maxWords else {
            // Transcript fits in single chunk
            logger.info("Transcript fits in single chunk (\(totalWords) words)", category: .transcription)
            return ChunkResult(chunks: [transcript], totalChunks: 1, wordsPerChunk: totalWords, overlapWords: 0)
        }

        var chunks: [String] = []
        var currentIndex = 0

        while currentIndex < totalWords {
            let endIndex = min(currentIndex + maxWords, totalWords)
            let chunkWords = words[currentIndex..<endIndex]
            let chunkText = chunkWords.joined(separator: " ")

            // Add chunk metadata
            let chunkNumber = chunks.count + 1
            let totalEstimatedChunks = estimateTotalChunks(totalWords: totalWords, maxWords: maxWords, overlapWords: overlapWords)

            let annotatedChunk = """
            [Chunk \(chunkNumber)/\(totalEstimatedChunks) of full transcript]

            \(chunkText)
            """

            chunks.append(annotatedChunk)

            // Move to next chunk with overlap
            // For last chunk, don't apply overlap
            if endIndex < totalWords {
                currentIndex += (maxWords - overlapWords)
            } else {
                break
            }
        }

        logger.info("Created \(chunks.count) chunks from \(totalWords) words", category: .transcription)

        return ChunkResult(
            chunks: chunks,
            totalChunks: chunks.count,
            wordsPerChunk: maxWords,
            overlapWords: overlapWords
        )
    }

    /// Estimate total number of chunks that will be created
    private func estimateTotalChunks(totalWords: Int, maxWords: Int, overlapWords: Int) -> Int {
        if totalWords <= maxWords {
            return 1
        }

        let effectiveChunkSize = maxWords - overlapWords
        let chunksNeeded = Int(ceil(Double(totalWords - maxWords) / Double(effectiveChunkSize))) + 1
        return chunksNeeded
    }

    /// Combine individual chunk summaries into a single text for meta-summarization
    /// - Parameter chunkSummaries: Array of markdown summaries from each chunk
    /// - Returns: Combined text ready for meta-summarization
    func combineSummariesForMetaPass(chunkSummaries: [String]) -> String {
        var combined = "# Individual Chunk Summaries to Combine\n\n"

        for (index, summary) in chunkSummaries.enumerated() {
            combined += "## Summary of Chunk \(index + 1)/\(chunkSummaries.count)\n\n"
            combined += summary
            combined += "\n\n---\n\n"
        }

        return combined
    }
}
