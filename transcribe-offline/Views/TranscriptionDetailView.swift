import SwiftUI
import AppKit

struct TranscriptionDetailView: View {
    let transcription: Transcription
    var onRetrySummarization: (() -> Void)? = nil

    @State private var selectedTab: Tab = .summary
    @State private var showCopySummaryCheck = false
    @State private var showCopyTranscriptCheck = false
    @State private var showExportAlert = false
    @State private var exportError: String?

    enum Tab {
        case summary
        case transcript
    }

    private var isSummarizationFailed: Bool {
        transcription.summaryStatus == .failed
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                Text(transcription.title)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                HStack(spacing: 8) {
                    Text(transcription.formattedFullDate())
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(transcription.duration)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text("\(transcription.wordCount) words")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // Provider (if summarized)
                    if let provider = transcription.summaryProvider {
                        Text("•")
                            .foregroundColor(.secondary)

                        Text(provider)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
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

            // Tab Picker
            HStack(spacing: 0) {
                TabButton(title: "Summary", isSelected: selectedTab == .summary) {
                    selectedTab = .summary
                }
                TabButton(title: "Transcript", isSelected: selectedTab == .transcript) {
                    selectedTab = .transcript
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .background(Color(nsColor: .textBackgroundColor))

            // Content
            switch selectedTab {
            case .summary:
                SelectableMarkdownText(markdown: transcription.summary)
            case .transcript:
                SelectableTranscriptText(text: transcription.transcript)
            }

            // Action bar with wrapping buttons
            FlowLayout(spacing: 12) {
                // (Re)Summarize button - always visible if callback provided
                if let onRetry = onRetrySummarization {
                    Button(action: onRetry) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14))
                                .frame(width: 14, height: 14)
                            Text(isSummarizationFailed ? "Summarize" : "Resummarize")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(minWidth: 130, minHeight: 32)
                        .padding(.horizontal, 16)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                // Copy Summary button
                Button(action: copySummary) {
                    HStack(spacing: 8) {
                        Image(systemName: showCopySummaryCheck ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 14, height: 14)
                        Text(showCopySummaryCheck ? "Copied" : "Copy Summary")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(minWidth: 130, minHeight: 32)
                    .padding(.horizontal, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Copy Transcript button
                Button(action: copyTranscript) {
                    HStack(spacing: 8) {
                        Image(systemName: showCopyTranscriptCheck ? "checkmark.circle.fill" : "doc.text")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 14, height: 14)
                        Text(showCopyTranscriptCheck ? "Copied" : "Copy Transcript")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(minWidth: 130, minHeight: 32)
                    .padding(.horizontal, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Export button
                Button(action: exportFiles) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 14, height: 14)
                        Text("Export...")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(minWidth: 130, minHeight: 32)
                    .padding(.horizontal, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1),
                alignment: .top
            )
        }
        .alert("Export Error", isPresented: .constant(exportError != nil)) {
            Button("OK") {
                exportError = nil
            }
        } message: {
            if let error = exportError {
                Text(error)
            }
        }
        .alert("Export Successful", isPresented: $showExportAlert) {
            Button("OK") {
                showExportAlert = false
            }
        } message: {
            Text("Files have been exported successfully.")
        }
    }

    // MARK: - Actions

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcription.summary, forType: .string)

        showCopySummaryCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopySummaryCheck = false
        }
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcription.transcript, forType: .string)

        showCopyTranscriptCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopyTranscriptCheck = false
        }
    }

    private func exportFiles() {
        let openPanel = NSOpenPanel()
        openPanel.message = "Choose folder to export summary and transcript"
        openPanel.canCreateDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Export Here"

        openPanel.begin { response in
            guard response == .OK, let directory = openPanel.url else {
                return
            }

            do {
                // Use sanitized title as base filename
                let baseName = sanitizeFilename(transcription.title)

                // Create summary file with metadata
                let summaryURL = directory
                    .appendingPathComponent("\(baseName)-summary")
                    .appendingPathExtension("md")

                let summaryContent = """
                ---
                Title: \(transcription.title)
                Date: \(transcription.formattedFullDate())
                Duration: \(transcription.duration)
                Word Count: \(transcription.wordCount)
                ---

                \(transcription.summary)
                """

                try summaryContent.write(to: summaryURL, atomically: true, encoding: .utf8)

                // Create transcript file
                let transcriptURL = directory
                    .appendingPathComponent("\(baseName)-transcript")
                    .appendingPathExtension("txt")

                try transcription.transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

                // Success
                showExportAlert = true

                // Reveal in Finder
                NSWorkspace.shared.selectFile(summaryURL.path, inFileViewerRootedAtPath: directory.path)

            } catch {
                exportError = "Failed to export: \(error.localizedDescription)"
            }
        }
    }

    private func sanitizeFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return filename.components(separatedBy: invalidCharacters).joined(separator: "-")
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Selectable Text Views

struct SelectableTranscriptText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }
}

struct SelectableMarkdownText: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.textColor = NSColor.labelColor

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView

        let attributedString = renderMarkdown(markdown)

        if textView.attributedString() != attributedString {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: .newlines)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        for line in lines {
            if line.hasPrefix("#### ") {
                // H4 heading
                let content = String(line.dropFirst(5))
                let processedLine = processInlineFormatting(
                    content,
                    baseFont: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    paragraphStyle: paragraphStyle
                )
                result.append(NSAttributedString(string: "\n"))
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else if line.hasPrefix("### ") {
                // H3 heading
                let content = String(line.dropFirst(4))
                let processedLine = processInlineFormatting(
                    content,
                    baseFont: NSFont.systemFont(ofSize: 15, weight: .semibold),
                    paragraphStyle: paragraphStyle
                )
                result.append(NSAttributedString(string: "\n"))
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else if line.hasPrefix("## ") {
                // H2 heading
                let content = String(line.dropFirst(3))
                let processedLine = processInlineFormatting(
                    content,
                    baseFont: NSFont.systemFont(ofSize: 17, weight: .semibold),
                    paragraphStyle: paragraphStyle
                )
                result.append(NSAttributedString(string: "\n"))
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else if line.hasPrefix("# ") {
                // H1 heading
                let content = String(line.dropFirst(2))
                let processedLine = processInlineFormatting(
                    content,
                    baseFont: NSFont.systemFont(ofSize: 22, weight: .bold),
                    paragraphStyle: paragraphStyle
                )
                result.append(NSAttributedString(string: "\n"))
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else if line.hasPrefix("  - ") {
                // Sub-bullet (indented with 2 spaces)
                let content = String(line.dropFirst(4))
                let processedLine = processInlineFormatting(
                    content,
                    baseFont: NSFont.systemFont(ofSize: 13),
                    paragraphStyle: paragraphStyle
                )
                let bullet = NSAttributedString(
                    string: "      ◦ ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraphStyle
                    ]
                )
                result.append(bullet)
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else if line.hasPrefix("- ") {
                // Main bullet point
                let content = String(line.dropFirst(2))
                let processedLine = processInlineFormatting(
                    content,
                    baseFont: NSFont.systemFont(ofSize: 13),
                    paragraphStyle: paragraphStyle
                )
                let bullet = NSAttributedString(
                    string: "  • ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraphStyle
                    ]
                )
                result.append(bullet)
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Paragraph
                let processedLine = processInlineFormatting(
                    line,
                    baseFont: NSFont.systemFont(ofSize: 13),
                    paragraphStyle: paragraphStyle
                )
                result.append(processedLine)
                result.append(NSAttributedString(string: "\n"))
            } else {
                // Empty line
                result.append(NSAttributedString(string: "\n"))
            }
        }

        return result
    }

    private func processInlineFormatting(_ text: String, baseFont: NSFont, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Regular expression to find **bold** and *italic*
        let boldPattern = "\\*\\*(.+?)\\*\\*"
        let italicPattern = "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"

        // Combine patterns - check bold first (longer pattern)
        let combinedPattern = "(\(boldPattern))|(\(italicPattern))"

        guard let regex = try? NSRegularExpression(pattern: combinedPattern, options: []) else {
            // Fallback if regex fails
            return NSAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ])
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        var lastPosition = 0

        for match in matches {
            // Add text before the match
            if match.range.location > lastPosition {
                let beforeRange = NSRange(location: lastPosition, length: match.range.location - lastPosition)
                let beforeText = nsString.substring(with: beforeRange)
                result.append(NSAttributedString(
                    string: beforeText,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraphStyle
                    ]
                ))
            }

            // Check if it's bold or italic
            if match.range(at: 1).location != NSNotFound {
                // Bold match (group 1)
                let contentRange = match.range(at: 2)
                let content = nsString.substring(with: contentRange)
                let boldFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                result.append(NSAttributedString(
                    string: content,
                    attributes: [
                        .font: boldFont,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraphStyle
                    ]
                ))
            } else if match.range(at: 3).location != NSNotFound {
                // Italic match (group 3)
                let contentRange = match.range(at: 4)
                let content = nsString.substring(with: contentRange)
                let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFont.pointSize) ?? baseFont
                result.append(NSAttributedString(
                    string: content,
                    attributes: [
                        .font: italicFont,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraphStyle
                    ]
                ))
            }

            lastPosition = match.range.location + match.range.length
        }

        // Add remaining text after last match
        if lastPosition < nsString.length {
            let remainingRange = NSRange(location: lastPosition, length: nsString.length - lastPosition)
            let remainingText = nsString.substring(with: remainingRange)
            result.append(NSAttributedString(
                string: remainingText,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle
                ]
            ))
        }

        return result
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if currentX + size.width > maxWidth && currentX > 0 {
                    // Move to next line
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

#Preview {
    TranscriptionDetailView(
        transcription: Transcription(
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

            ## Action Items
            - **Sarah** - Complete UI mockups by Jan 18
            - **Mike** - Set up Ollama test environment
            """,
            transcript: "Full transcript would be here...",
            wordCount: 1247,
            summaryStatus: .completed,
            summaryProvider: "Apple Intelligence"
        )
    )
    .frame(width: 800, height: 600)
}
