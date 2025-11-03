import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    @State private var isTestingLocalConnection = false
    @State private var testLocalConnectionResult: TestResult?
    @State private var isTestingRemoteConnection = false
    @State private var testRemoteConnectionResult: TestResult?
    @State private var providerAvailability: [String: Bool] = [:]
    @State private var isCheckingProviders = false
    @State private var showAdvancedOptions = false
    @State private var showDiagnosticsCopied = false
    @State private var logger = Logger.shared

    enum TestResult {
        case success(String)
        case failure(String)
    }

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

                                // Advanced Options Disclosure
                                DisclosureGroup(isExpanded: $showAdvancedOptions) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        // Provider Selection
                                        VStack(alignment: .leading, spacing: 4) {
                                            // Auto mode
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 8) {
                                                    Button(action: {
                                                        settings.selectedProvider = nil
                                                    }) {
                                                        HStack(spacing: 8) {
                                                            Image(systemName: settings.selectedProvider == nil ? "largecircle.fill.circle" : "circle")
                                                                .foregroundColor(settings.selectedProvider == nil ? .accentColor : .secondary)

                                                            Text("Auto")
                                                                .foregroundColor(.primary)

                                                            Spacer()
                                                        }
                                                    }
                                                    .buttonStyle(.plain)
                                                }

                                                Text("Tries providers in order: Ollama (Local/LAN) → Apple Intelligence → Ollama (Remote)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .italic()
                                                    .padding(.leading, 28)
                                            }
                                            .padding(.vertical, 4)

                                            // Ollama Local
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 8) {
                                                    Button(action: {
                                                        settings.selectedProvider = .ollamaLocal
                                                    }) {
                                                        HStack(spacing: 8) {
                                                            Image(systemName: settings.selectedProvider == .ollamaLocal ? "largecircle.fill.circle" : "circle")
                                                                .foregroundColor(settings.selectedProvider == .ollamaLocal ? .accentColor : .secondary)

                                                            Text("Ollama (Local/LAN)")
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
                                                            if let isAvailable = providerAvailability[SummarizationProviderType.ollamaLocal.rawValue] {
                                                                Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                                    .foregroundColor(isAvailable ? .green : .red)
                                                                    .font(.caption)
                                                            }
                                                        }
                                                    }
                                                    .buttonStyle(.plain)
                                                }

                                                Text("Private: Only allows localhost and private network connections (192.168.x.x, 10.x.x.x)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .italic()
                                                    .padding(.leading, 28)
                                            }
                                            .padding(.vertical, 4)

                                            // Ollama Remote
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 8) {
                                                    Button(action: {
                                                        settings.selectedProvider = .ollamaRemote
                                                    }) {
                                                        HStack(spacing: 8) {
                                                            Image(systemName: settings.selectedProvider == .ollamaRemote ? "largecircle.fill.circle" : "circle")
                                                                .foregroundColor(settings.selectedProvider == .ollamaRemote ? .accentColor : .secondary)

                                                            Text("Ollama (Remote/Custom)")
                                                                .foregroundColor(.primary)

                                                            Spacer()

                                                            Text("⚠️ Advanced")
                                                                .font(.caption2)
                                                                .padding(.horizontal, 6)
                                                                .padding(.vertical, 2)
                                                                .background(Color.orange.opacity(0.2))
                                                                .foregroundColor(.orange)
                                                                .cornerRadius(4)

                                                            // Availability indicator
                                                            if let isAvailable = providerAvailability[SummarizationProviderType.ollamaRemote.rawValue] {
                                                                Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                                    .foregroundColor(isAvailable ? .green : .red)
                                                                    .font(.caption)
                                                            }
                                                        }
                                                    }
                                                    .buttonStyle(.plain)
                                                }

                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("⚠️ Privacy Warning")
                                                        .font(.caption)
                                                        .fontWeight(.semibold)
                                                        .foregroundColor(.orange)
                                                        .padding(.leading, 28)

                                                    Text("This option allows unencrypted HTTP connections to ANY server. Only use with:")
                                                        .font(.caption2)
                                                        .foregroundColor(.orange)
                                                        .padding(.leading, 28)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("• Tailscale (100.x.x.x - encrypted tunnel)")
                                                        Text("• VPN connections")
                                                        Text("• HTTPS endpoints (always encrypted)")
                                                    }
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .padding(.leading, 36)

                                                    Text("NOT recommended for plain HTTP over public internet.")
                                                        .font(.caption2)
                                                        .fontWeight(.medium)
                                                        .foregroundColor(.red)
                                                        .padding(.leading, 28)
                                                }
                                                .padding(.top, 4)
                                            }
                                            .padding(.vertical, 4)
                                        }

                                        Divider()

                                        // Ollama Local Configuration
                                        VStack(alignment: .leading, spacing: 12) {
                                            HStack {
                                                Text("Ollama (Local/LAN) Configuration")
                                                    .font(.headline)
                                                    .fontWeight(.semibold)

                                                Text("Private")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.2))
                                                    .foregroundColor(.green)
                                                    .cornerRadius(4)
                                            }

                                            Text("For localhost and private networks (192.168.x.x, 10.x.x.x)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)

                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("Base URL")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                TextField("http://localhost:11434", text: $settings.ollamaLocalBaseURL)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.body.monospaced())
                                                    .lineLimit(1)
                                            }

                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("Model")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                HStack {
                                                    TextField("qwen2.5", text: $settings.ollamaLocalModel)
                                                        .textFieldStyle(.roundedBorder)

                                                    Menu {
                                                        Button("llama3.1") { settings.ollamaLocalModel = "llama3.1" }
                                                        Button("llama3.2") { settings.ollamaLocalModel = "llama3.2" }
                                                        Button("qwen2.5") { settings.ollamaLocalModel = "qwen2.5" }
                                                        Button("mistral") { settings.ollamaLocalModel = "mistral" }
                                                        Button("gemma2") { settings.ollamaLocalModel = "gemma2" }
                                                    } label: {
                                                        Image(systemName: "chevron.down.circle")
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .menuStyle(.borderlessButton)
                                                    .fixedSize()
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack {
                                                    Text("API Key")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text("(Optional)")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .italic()
                                                }
                                                SecureField("Leave blank if not required", text: $settings.ollamaLocalAPIKey)
                                                    .textFieldStyle(.roundedBorder)
                                            }

                                            // Test Local Connection Button
                                            HStack(spacing: 12) {
                                                Button(action: testLocalConnection) {
                                                    HStack(spacing: 8) {
                                                        if isTestingLocalConnection {
                                                            ProgressView()
                                                                .scaleEffect(0.7)
                                                                .frame(width: 16, height: 16)
                                                        } else {
                                                            Image(systemName: "network")
                                                        }
                                                        Text("Test Connection")
                                                    }
                                                }
                                                .disabled(isTestingLocalConnection)

                                                // Status indicator
                                                if let result = testLocalConnectionResult {
                                                    switch result {
                                                    case .success:
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundColor(.green)
                                                            .font(.system(size: 16))
                                                    case .failure(let message):
                                                        Image(systemName: "xmark.circle.fill")
                                                            .foregroundColor(.red)
                                                            .font(.system(size: 16))
                                                            .help(message)
                                                    }
                                                }
                                            }
                                            .padding(.top, 4)
                                        }

                                        Divider()

                                        // Ollama Remote Configuration
                                        VStack(alignment: .leading, spacing: 12) {
                                            HStack {
                                                Text("Ollama (Remote/Custom) Configuration")
                                                    .font(.headline)
                                                    .fontWeight(.semibold)

                                                Text("⚠️ Advanced")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.2))
                                                    .foregroundColor(.orange)
                                                    .cornerRadius(4)
                                            }

                                            Text("For Tailscale (100.x.x.x), VPN, or HTTPS endpoints")
                                                .font(.caption)
                                                .foregroundColor(.secondary)

                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("Base URL")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                TextField("e.g., https://your-server.com:11434", text: $settings.ollamaRemoteBaseURL)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.body.monospaced())
                                                    .lineLimit(1)
                                            }

                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("Model")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                HStack {
                                                    TextField("qwen2.5", text: $settings.ollamaRemoteModel)
                                                        .textFieldStyle(.roundedBorder)

                                                    Menu {
                                                        Button("llama3.1") { settings.ollamaRemoteModel = "llama3.1" }
                                                        Button("llama3.2") { settings.ollamaRemoteModel = "llama3.2" }
                                                        Button("qwen2.5") { settings.ollamaRemoteModel = "qwen2.5" }
                                                        Button("mistral") { settings.ollamaRemoteModel = "mistral" }
                                                        Button("gemma2") { settings.ollamaRemoteModel = "gemma2" }
                                                    } label: {
                                                        Image(systemName: "chevron.down.circle")
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .menuStyle(.borderlessButton)
                                                    .fixedSize()
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack {
                                                    Text("API Key")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text("(Optional)")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                        .italic()
                                                }
                                                SecureField("Leave blank if not required", text: $settings.ollamaRemoteAPIKey)
                                                    .textFieldStyle(.roundedBorder)
                                            }

                                            // Test Remote Connection Button
                                            HStack(spacing: 12) {
                                                Button(action: testRemoteConnection) {
                                                    HStack(spacing: 8) {
                                                        if isTestingRemoteConnection {
                                                            ProgressView()
                                                                .scaleEffect(0.7)
                                                                .frame(width: 16, height: 16)
                                                        } else {
                                                            Image(systemName: "network")
                                                        }
                                                        Text("Test Connection")
                                                    }
                                                }
                                                .disabled(isTestingRemoteConnection)

                                                // Status indicator
                                                if let result = testRemoteConnectionResult {
                                                    switch result {
                                                    case .success:
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundColor(.green)
                                                            .font(.system(size: 16))
                                                    case .failure(let message):
                                                        Image(systemName: "xmark.circle.fill")
                                                            .foregroundColor(.red)
                                                            .font(.system(size: 16))
                                                            .help(message)
                                                    }
                                                }
                                            }
                                            .padding(.top, 4)
                                        }
                                    }
                                    .padding(.top, 8)
                                } label: {
                                    Text("Advanced Options - configure local/remote LLM for summarization")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 8)
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
                                Text("0.2.2-experimental")
                                    .foregroundColor(.orange)
                            }
                            .font(.caption)

                            HStack {
                                Spacer()
                                Text("⚠️ EXPERIMENTAL")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.15))
                                    .cornerRadius(4)
                                Spacer()
                            }
                            .padding(.vertical, 4)

                            Text("Experimental release with Ollama support. Use stable branch for maximum privacy.")
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

                            Text("Privacy: Transcription is performed locally on your device. Only the transcript text is sent to your configured AI provider for summarization.")
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
                            testLocalConnectionResult = nil
                            testRemoteConnectionResult = nil
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

    private func testLocalConnection() {
        isTestingLocalConnection = true
        testLocalConnectionResult = nil

        Task {
            do {
                try await OllamaLocalService.shared.testConnection()
                await MainActor.run {
                    testLocalConnectionResult = .success("Connected successfully")
                    isTestingLocalConnection = false
                    checkProviderAvailability()
                }
            } catch {
                await MainActor.run {
                    testLocalConnectionResult = .failure(error.localizedDescription)
                    isTestingLocalConnection = false
                    checkProviderAvailability()
                }
            }
        }
    }

    private func testRemoteConnection() {
        isTestingRemoteConnection = true
        testRemoteConnectionResult = nil

        Task {
            do {
                try await OllamaRemoteService.shared.testConnection()
                await MainActor.run {
                    testRemoteConnectionResult = .success("Connected successfully")
                    isTestingRemoteConnection = false
                    checkProviderAvailability()
                }
            } catch {
                await MainActor.run {
                    testRemoteConnectionResult = .failure(error.localizedDescription)
                    isTestingRemoteConnection = false
                    checkProviderAvailability()
                }
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
