import SwiftUI

struct ContentAreaView: View {
    let state: RecorderState
    let duration: TimeInterval
    let progress: Double
    let progressMessage: String?
    let selectedTranscription: Transcription?
    let showSettings: Bool
    let onRetry: () -> Void
    let onRetryForTranscription: ((Transcription) -> Void)?

    var body: some View {
        Group {
            if showSettings {
                SettingsView()
            } else if let transcription = selectedTranscription {
                // If a transcription is selected, ALWAYS show it (even if recorder is in error state)
                // This allows users to navigate to historical transcriptions during/after errors
                TranscriptionDetailView(
                    transcription: transcription,
                    onRetrySummarization: {
                        onRetryForTranscription?(transcription)
                    }
                )
            } else {
                // No transcription selected - show the recorder's current state
                switch state {
                case .recording:
                    RecordingStateView(duration: duration)

                case .stopped, .transcribing, .summarizing:
                    ProcessingStateView(state: state, progress: progress, progressMessage: progressMessage)

                case .error(let message, let transcript):
                    ErrorStateView(message: message, transcript: transcript, onRetry: onRetry)

                case .idle, .complete:
                    EmptyStateView()
                }
            }
        }
    }
}

#Preview("Empty") {
    ContentAreaView(
        state: .idle,
        duration: 0,
        progress: 0,
        progressMessage: nil,
        selectedTranscription: nil,
        showSettings: false,
        onRetry: {},
        onRetryForTranscription: nil
    )
    .frame(width: 600, height: 500)
}

#Preview("Recording") {
    ContentAreaView(
        state: .recording,
        duration: 125,
        progress: 0,
        progressMessage: nil,
        selectedTranscription: nil,
        showSettings: false,
        onRetry: {},
        onRetryForTranscription: nil
    )
    .frame(width: 600, height: 500)
}

#Preview("Transcribing") {
    ContentAreaView(
        state: .transcribing(progress: 0.67),
        duration: 0,
        progress: 0.67,
        progressMessage: "Chunk 8/12 • 35-40 min",
        selectedTranscription: nil,
        showSettings: false,
        onRetry: {},
        onRetryForTranscription: nil
    )
    .frame(width: 600, height: 500)
}

#Preview("Detail") {
    ContentAreaView(
        state: .idle,
        duration: 0,
        progress: 0,
        progressMessage: nil,
        selectedTranscription: Transcription(
            title: "Product Strategy Meeting",
            date: Date(),
            duration: "24:15",
            summary: """
            ## Meeting Overview
            This was a product strategy discussion focused on Q1 2025 planning.

            ## Key Decisions
            - Moving forward with local transcription using Whisper
            - Ollama integration approved for summarization
            - Target release: End of January 2025
            """,
            transcript: "Full transcript would be here...",
            wordCount: 1247,
            summaryStatus: .completed
        ),
        showSettings: false,
        onRetry: {},
        onRetryForTranscription: nil
    )
    .frame(width: 600, height: 500)
}

#Preview("Settings") {
    ContentAreaView(
        state: .idle,
        duration: 0,
        progress: 0,
        progressMessage: nil,
        selectedTranscription: nil,
        showSettings: true,
        onRetry: {},
        onRetryForTranscription: nil
    )
    .frame(width: 600, height: 500)
}

#Preview("Failed Summarization") {
    ContentAreaView(
        state: .idle,
        duration: 0,
        progress: 0,
        progressMessage: nil,
        selectedTranscription: Transcription(
            title: "Transcription complete (summarization failed)",
            date: Date(),
            duration: "12:34",
            summary: "Failed to connect to Ollama: Connection refused",
            transcript: "This is the full transcript that was successfully transcribed but failed to be summarized due to Ollama connection issues. The transcript is preserved so it can be retried later.",
            wordCount: 523,
            summaryStatus: .failed
        ),
        showSettings: false,
        onRetry: {},
        onRetryForTranscription: { transcription in
            print("Retrying summarization for: \(transcription.title)")
        }
    )
    .frame(width: 600, height: 500)
}
