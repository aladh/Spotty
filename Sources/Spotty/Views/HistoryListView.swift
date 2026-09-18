import SpottyDomain
import SwiftUI

struct HistoryListView: View {
    let entries: [HistoryEntry]
    let actions: SidePanelPlaybackActions
    @Binding var selection: Set<HistoryEntry.ID>
    let scrollState: NativeListScrollState

    var body: some View {
        if entries.isEmpty {
            EmptyState(
                icon: "clock.arrow.circlepath", title: "No listening history yet",
                message: "Tracks you play will appear here.")
        } else {
            NativeOccurrenceList(
                rows: entries.map { entry in
                    NativeOccurrenceListRow(
                        id: entry.id, height: 64,
                        content: AnyView(
                            HistoryRow(entry: entry, canPlay: actions.canStartPlayback) {
                                actions.activateHistorySelection([entry.id])
                            }))
                },
                selection: $selection, allowsMultipleSelection: false, accessibilityLabel: "Recently played",
                scrollState: scrollState, primaryAction: actions.activateHistorySelection
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let canPlay: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(url: entry.artworkURL, kind: .track, cornerRadius: 4)
                .frame(width: 48, height: 48)
                .overlay {
                    CatalogCardButton(isPointerRevealed: isHovering, action: action) { isFocused in
                        ZStack {
                            Color.black.opacity(0.5)
                            Image(systemName: "play.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(isHovering || isFocused ? (canPlay ? 1 : 0.4) : 0)
                    }
                    .disabled(!canPlay)
                    .pointingHandCursor(enabled: canPlay)
                    .help("Play \(entry.title)")
                    .accessibilityLabel("Play \(entry.title) by \(entry.artist)")
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 16))
                    .foregroundStyle(SpottyPalette.textPrimary)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(
            SpottyPalette.historySurface(isHovering: isHovering),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .pointingHandCursor(isHovering: $isHovering)
        .onDisappear { isHovering = false }
        .accessibilityElement(children: .contain)
        .accessibilityValue("Played \(entry.playedAt.formatted(.relative(presentation: .named)))")
    }
}
