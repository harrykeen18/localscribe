import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    @State private var providerAvailability: [String: Bool] = [:]
    @State private var isCheckingProviders = false
    @State private var showDiagnosticsCopied = false
    @State private var logger = Logger.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title)
                    .fontWeight(.semibold)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1),
                alignment: .bottom
            )

            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Summarization Provider Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Summarization Provider")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Spacer()

                            Button(action: checkProviderAvailability) {
                                HStack(spacing: 4) {
                                    if isCheckingProviders {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .frame(width: 12, height: 12)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.caption)
                                    }
                                    Text("Check Status")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isCheckingProviders)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose which AI service to use for summarization:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Primary Provider: Apple Intelligence
                            VStack(alignment: .leading, spacing: 4) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            settings.selectedProvider = .foundationModels
                                        }) {
                                            HStack(spacing: 8) {
                                                Image(systemName: settings.selectedProvider == .foundationModels ? "largecircle.fill.circle" : "circle")
                                                    .foregroundColor(settings.selectedProvider == .foundationModels ? .accentColor : .secondary)

                                                Text("Apple Intelligence")
                                                    .foregroundColor(.primary)

                                                Spacer()

                                                Text("Private")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.2))
                                                    .foregroundColor(.green)
                                                    .cornerRadius(4)

                                                // Availability indicator
                                                if let isAvailable = providerAvailability[SummarizationProviderType.foundationModels.rawValue] {
                                                    Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                        .foregroundColor(isAvailable ? .green : .red)
                                                        .font(.caption)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Text("Make sure Apple Intelligence is downloaded and enabled in settings.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding(.leading, 28)
                                }
                                .padding(.vertical, 4)
                            }
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)

                    // About Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("About")
                            .font(.title2)
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Version")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("0.2.2-beta")
                                    .foregroundColor(.blue)
                            }
                            .font(.caption)

                            HStack {
                                Spacer()
                                Text("🧪 BETA VERSION")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.15))
                                    .cornerRadius(4)
                                Spacer()
                            }
                            .padding(.vertical, 4)

                            Text("This is pre-release software. Please report bugs via GitHub Issues.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)

                            Divider()

                            Text("LocalScribe captures system audio and transcribes it locally using Whisper.cpp, then summarizes it using Apple Intelligence.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            Text("Privacy: 100% on-device processing. Transcription uses Whisper.cpp and summarization uses Apple Intelligence. No data ever leaves your Mac.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)

                    // Diagnostics Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Diagnostics")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Export logs for troubleshooting. No transcript content is included.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Button(action: copyDiagnosticsToClipboard) {
                                HStack(spacing: 8) {
                                    Image(systemName: showDiagnosticsCopied ? "checkmark.circle.fill" : "doc.on.clipboard")
                                        .foregroundColor(showDiagnosticsCopied ? .green : .primary)
                                    Text(showDiagnosticsCopied ? "Copied!" : "Copy to Clipboard")
                                }
                                .frame(minWidth: 160)
                            }
                            .buttonStyle(.bordered)

                            Button(action: saveDiagnosticsToFile) {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Save to File")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)

                    // Reset Button
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            settings.resetToDefaults()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear {
            checkProviderAvailability()
        }
    }

    private func checkProviderAvailability() {
        isCheckingProviders = true

        Task {
            let availability = await SummarizationManager.shared.checkAllProviders()

            await MainActor.run {
                providerAvailability = availability
                isCheckingProviders = false
            }
        }
    }

    private func copyDiagnosticsToClipboard() {
        logger.exportDiagnostics()

        // Show visual feedback
        showDiagnosticsCopied = true

        // Reset after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showDiagnosticsCopied = false
        }
    }

    private func saveDiagnosticsToFile() {
        logger.exportDiagnosticsToFile()
    }
}

#Preview {
    SettingsView()
}
