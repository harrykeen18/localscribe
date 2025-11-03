import SwiftUI

struct ToolbarView: View {
    let state: RecorderState
    let duration: TimeInterval
    let progress: Double
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Left: Recording control button
            HStack(spacing: 12) {
                recordingButton
            }

            Spacer()

            // Right: Settings button
            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "gear")
                        .font(.system(size: 14, weight: .medium))
                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: 56)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var recordingButton: some View {
        switch state {
        case .idle, .complete, .error:
            Button(action: onStartRecording) {
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 14, weight: .medium))
                    Text("Start Recording")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(minWidth: 130)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

        case .recording:
            Button(action: onStopRecording) {
                HStack(spacing: 8) {
                    Image(systemName: "square.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("Stop Recording")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(minWidth: 130)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

        case .stopped, .transcribing, .summarizing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text("Processing")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(minWidth: 130)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.3))
            .foregroundColor(.secondary)
            .cornerRadius(6)
        }
    }

}

#Preview("Idle") {
    ToolbarView(
        state: .idle,
        duration: 0,
        progress: 0,
        onStartRecording: {},
        onStopRecording: {},
        onOpenSettings: {}
    )
}

#Preview("Recording") {
    ToolbarView(
        state: .recording,
        duration: 125,
        progress: 0,
        onStartRecording: {},
        onStopRecording: {},
        onOpenSettings: {}
    )
}

#Preview("Transcribing") {
    ToolbarView(
        state: .transcribing(progress: 0.67),
        duration: 0,
        progress: 0.67,
        onStartRecording: {},
        onStopRecording: {},
        onOpenSettings: {}
    )
}
