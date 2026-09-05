import AppKit
import SpottyDomain
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    let library: [PlaylistLibraryNode]
    let playback: CatalogPlaybackAccess
    @State private var expandedFolders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playlists")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpottyPalette.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .accessibilityAddTraits(.isHeader)

            List(selection: $selection) {
                ForEach(PlaylistLibraryNode.visibleRows(library, expanded: expandedFolders)) { row in
                    Group {
                        if let playlist = row.node.playlist {
                            SidebarPlaylistRow(
                                playlist: playlist, isSelected: selection == .playlist(playlist.uri), playback: playback
                            )
                            .tag(SidebarSelection.playlist(playlist.uri))
                        } else {
                            SidebarFolderRow(node: row.node, isExpanded: expandedFolders.contains(row.id)) {
                                if !expandedFolders.insert(row.id).inserted { expandedFolders.remove(row.id) }
                            }
                            .selectionDisabled()
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 64)
            .accessibilityLabel("Playlists")
        }
        .background { SpottyPalette.catalogCanvas.ignoresSafeArea() }
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

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(
                url: playlist.artworkURL,
                kind: .playlist,
                cornerRadius: 4,
                pointSize: 48
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
                    .font(.system(size: 16))
                    .lineLimit(1)
                Text(playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            isSelected ? Color(white: 0.157) : (isHovering ? Color(white: 0.122) : .clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .background { PlaylistSelectionAppearance() }
        .contentShape(Rectangle())
        .pointingHandCursor(isHovering: $isHovering)
        .onDisappear { isHovering = false }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(playlist.title)
        .accessibilityValue(playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle)
        .help(playlist.title)
    }
}
