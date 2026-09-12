import SpottyDomain
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    let library: [PlaylistLibraryNode]
    let playback: CatalogPlaybackAccess
    var isLoading = false
    @State private var expandedFolders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your Library")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpottyPalette.textPrimary)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .accessibilityAddTraits(.isHeader)

            NativeOccurrenceList(
                rows: nativeRows, selection: nativeSelection,
                allowsMultipleSelection: false, drawsSelection: false,
                accessibilityLabel: "Playlists"
            )
            .overlay {
                if library.isEmpty && isLoading {
                    ProgressView("Loading playlists")
                        .controlSize(.small)
                        .font(.caption)
                }
            }
        }
        .background { SpottyPalette.catalogCanvas.ignoresSafeArea() }
    }

    private var nativeSelection: Binding<Set<String>> {
        Binding(
            get: {
                guard let selection, case let .playlist(uri) = selection else { return [] }
                return [uri]
            },
            set: { selection = $0.first.map(SidebarSelection.playlist) }
        )
    }

    private var nativeRows: [NativeOccurrenceListRow] {
        PlaylistLibraryNode.visibleRows(library, expanded: expandedFolders).map { row in
            NativeOccurrenceListRow(
                id: row.id, height: 64, isSelectable: row.node.playlist != nil,
                content: AnyView(
                    sidebarRow(row)
                        .padding(.leading, CGFloat(row.depth) * 16)
                        .padding(.horizontal, 8)
                )
            )
        }
    }

    @ViewBuilder
    private func sidebarRow(_ row: PlaylistLibraryNode.VisibleRow) -> some View {
        if let playlist = row.node.playlist {
            SidebarPlaylistRow(
                playlist: playlist, isSelected: selection == .playlist(playlist.uri), playback: playback
            )
        } else {
            SidebarFolderRow(node: row.node, isExpanded: expandedFolders.contains(row.id)) {
                if !expandedFolders.insert(row.id).inserted { expandedFolders.remove(row.id) }
            }
        }
    }
}

private struct SidebarFolderRow: View {
    let node: PlaylistLibraryNode
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 24))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(SpottyPalette.navigationControl, in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.title).font(.system(size: 16)).lineLimit(1)
                    Text(node.folderSummary).font(.system(size: 14))
                        .foregroundStyle(SpottyPalette.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SpottyPalette.textSecondary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(isHovering ? SpottyPalette.navigationControl : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(isHovering: $isHovering)
        .onDisappear { isHovering = false }
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(node.title)")
        .accessibilityValue(node.folderSummary)
    }
}

private struct SidebarPlaylistRow: View {
    let playlist: CatalogItem
    let isSelected: Bool
    let playback: CatalogPlaybackAccess
    @State private var isHovering = false

    @Environment(\.controlActiveState) private var controlActiveState

    private var isPlaying: Bool { playback.isPlayingPlaylist(playlist.uri) }

    private var selectedBackground: Color {
        controlActiveState == .inactive ? SpottyPalette.selectedControlInactive : SpottyPalette.selectedControl
    }

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(
                url: playlist.artworkURL,
                kind: .playlist,
                cornerRadius: 4
            )
            .frame(width: 48, height: 48)
            .overlay {
                Button {
                    playback.playPlaylist(playlist)
                } label: {
                    ZStack {
                        Color.black.opacity(0.5)
                        TransportSymbol(kind: .play)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!playback.canStartPlayback)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .pointingHandCursor(enabled: playback.canStartPlayback)
                .accessibilityLabel("Play \(playlist.title)")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .foregroundStyle(isPlaying ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary)
                    .font(.system(size: 16))
                    .lineLimit(1)
                Text(playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.mediaGreen)
                    .accessibilityHidden(true)
            }
        }
        .padding(8)
        .background(
            isSelected
                ? selectedBackground
                : (isHovering ? SpottyPalette.navigationControl : .clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .pointingHandCursor(isHovering: $isHovering)
        .onDisappear { isHovering = false }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(playlist.title)
        .accessibilityValue(
            (playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle) + (isPlaying ? ", Playing" : "")
        )
        .help(playlist.title)
    }
}
