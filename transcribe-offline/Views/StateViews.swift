import SwiftUI

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 4) {
                Text("No Recording Selected")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text("Select a recording from the sidebar or start a new one")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Recording State

struct RecordingStateView: View {
    let duration: TimeInterval

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Fixed height spacer to position circle
                Spacer()
                    .frame(height: 120)

                // Large pulsing red circle - fixed position
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.1))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )

                    Circle()
                        .fill(Color.red)
                        .frame(width: 80, height: 80)

                    Circle()
                        .strokeBorder(Color.white, lineWidth: 4)
                        .frame(width: 48, height: 48)
                }
                .frame(width: 120, height: 120)
                .onAppear {
                    pulseAnimation = true
                }

                // Text content below circle
                VStack(spacing: 8) {
                    Text(formatDuration(duration))
                        .font(.system(size: 48, weight: .medium, design: .rounded))
                        .foregroundColor(.primary)
                        .monospacedDigit()

                    Text("Recording in progress")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 24)

                Spacer()
            }
        }
    }

    @State private var pulseAnimation = false

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Processing State

struct ProcessingStateView: View {
    let state: RecorderState
    let progress: Double
    var progressMessage: String? = nil

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Fixed height spacer to position circle at same location as recording
                Spacer()
                    .frame(height: 120)

                // Animated circle - matches recording state size and position
                ZStack {
                    // Outer pulsing circle
                    Circle()
                        .fill(statusColor.opacity(0.1))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: true),
                            value: pulseAnimation
                        )

                    // Main circle
                    Circle()
                        .fill(statusColor)
                        .frame(width: 80, height: 80)

                    // Inner icon or progress
                    if case .transcribing = state {
                        // Show progress ring for transcribing
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 4)
                                .frame(width: 48, height: 48)

                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 48, height: 48)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.3), value: progress)
                        }
                    } else {
                        // Rotating dots for other states
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 48, height: 48)
                            .rotationEffect(.degrees(rotation))
                            .animation(
                                .linear(duration: 1.0)
                                .repeatForever(autoreverses: false),
                                value: rotation
                            )
                    }
                }
                .frame(width: 120, height: 120)
                .onAppear {
                    pulseAnimation = true
                    rotation = 360
                }

                // Text content below circle
                VStack(spacing: 12) {
                    Text(statusTitle)
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(statusSubtitle)
                        .font(.body)
                        .foregroundColor(.secondary)

                    // Progress percentage for transcribing
                    if case .transcribing = state {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                            .padding(.top, 8)

                        // Show chunk progress message if available
                        if let message = progressMessage, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.top, 24)

                Spacer()
            }
        }
    }

    @State private var pulseAnimation = false
    @State private var rotation: Double = 0

    private var statusColor: Color {
        switch state {
        case .transcribing:
            return .blue
        case .summarizing:
            return .purple
        default:
            return .blue
        }
    }

    private var statusTitle: String {
        switch state {
        case .stopped:
            return "Processing..."
        case .transcribing:
            return "Transcribing Audio"
        case .summarizing:
            return "Generating Summary"
        default:
            return "Processing..."
        }
    }

    private var statusSubtitle: String {
        switch state {
        case .stopped:
            return "Preparing your recording"
        case .transcribing:
            return "Converting your audio to text..."
        case .summarizing:
            return "Creating a structured summary..."
        default:
            return "Please wait..."
        }
    }
}

// MARK: - Error State

struct ErrorStateView: View {
    let message: String
    let transcript: TranscriptionResult?
    let onRetry: () -> Void

    var body: some View {
        if let transcript = transcript {
            // Show transcript with error message
            VStack(spacing: 0) {
                // Error banner
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)

                    Text(message)
                        .font(.body)
                        .foregroundColor(.primary)

                    Spacer()

                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .overlay(
                    Rectangle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(height: 1),
                    alignment: .bottom
                )

                // Transcript content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Transcription")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(transcript.text)
                            .font(.body)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            // Standard error view without transcript
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                VStack(spacing: 8) {
                    Text("Error")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(message)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                }

                Button(action: onRetry) {
                    Text("Retry Transcription")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    EmptyStateView()
}

#Preview("Recording") {
    RecordingStateView(duration: 125)
}

#Preview("Transcribing") {
    ProcessingStateView(
        state: .transcribing(progress: 0.67),
        progress: 0.67
    )
}

#Preview("Summarizing") {
    ProcessingStateView(
        state: .summarizing,
        progress: 0
    )
}

#Preview("Error") {
    ErrorStateView(
        message: "Failed to transcribe audio. Please check your Whisper configuration.",
        transcript: nil,
        onRetry: {}
    )
}
