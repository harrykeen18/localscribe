import SwiftUI

struct TranscriptionSidebarView: View {
    @ObservedObject var historyManager: TranscriptionHistoryManager
    @Binding var selectedId: UUID?
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Transcription list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let grouped = historyManager.getGrouped()

                    // Today section
                    if !grouped.today.isEmpty {
                        SidebarSection(title: "Today", transcriptions: grouped.today, selectedId: $selectedId, showSettings: $showSettings)
                    }

                    // Previous 7 Days section
                    if !grouped.previous7Days.isEmpty {
                        SidebarSection(title: "Previous 7 Days", transcriptions: grouped.previous7Days, selectedId: $selectedId, showSettings: $showSettings)
                    }

                    // Older section
                    if !grouped.older.isEmpty {
                        SidebarSection(title: "Older", transcriptions: grouped.older, selectedId: $selectedId, showSettings: $showSettings)
                    }

                    // Empty state
                    if historyManager.transcriptions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)

                            Text("No Recordings Yet")
                                .font(.headline)
                                .foregroundColor(.primary)

                            Text("Start a new recording\nto see it here")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(8)
            }
        }
        .frame(idealWidth: 280, maxWidth: 280)
        .frame(minWidth: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SidebarSection: View {
    let title: String
    let transcriptions: [Transcription]
    @Binding var selectedId: UUID?
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Section items
            ForEach(transcriptions) { transcription in
                SidebarItemView(
                    transcription: transcription,
                    isSelected: selectedId == transcription.id,
                    onSelect: {
                        selectedId = transcription.id
                        showSettings = false
                    }
                )
            }
        }
    }
}

struct SidebarItemView: View {
    let transcription: Transcription
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(transcription.title)
                    .font(.system(size: 13))
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Date and duration
                HStack(spacing: 4) {
                    Text(transcription.formattedDate())
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)

                    Text("•")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)

                    Text(transcription.duration)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered {
            return Color(nsColor: .controlBackgroundColor).opacity(0.5)
        } else {
            return Color.clear
        }
    }
}

#Preview {
    TranscriptionSidebarView(
        historyManager: TranscriptionHistoryManager.shared,
        selectedId: .constant(nil),
        showSettings: .constant(false)
    )
    .frame(height: 600)
}
