import SpottyDomain
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    let library: [PlaylistLibraryNode]
    let playback: CatalogPlaybackAccess
    var isLoading = false
    var hasLoaded = false
    var isCached = false
    var isRefreshing = false
    var error: String?
    var retry: (() async -> Void)?
    @State private var expandedFolders: Set<String> = []
    @State private var focusedFolder: FolderFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your Library")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SpottyPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isCached || error != nil {
                    Image(systemName: error == nil ? "clock" : "exclamationmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(SpottyPalette.textSecondary)
                        .help(libraryStatus)
                        .accessibilityLabel(libraryStatus)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            NativeOccurrenceList(
                rows: nativeRows, selection: nativeSelection,
                allowsMultipleSelection: false, drawsSelection: false,
                preservesVisibleAnchor: true,
                accessibilityLabel: "Playlists",
                primaryAction: { ids in
                    guard ids.count == 1, let id = ids.first else { return }
                    toggleFolder(id)
                }
            )
            .overlay {
                if library.isEmpty { emptyLibraryContent }
            }
        }
        .background { SpottyPalette.catalogCanvas.ignoresSafeArea() }
        .onChange(of: selection) {
            if focusedFolder?.route != selection { focusedFolder = nil }
        }
        .onChange(of: visibleRows.map(\.id)) { _, ids in
            if let focusedFolder, !ids.contains(focusedFolder.id) { self.focusedFolder = nil }
        }
        .onChange(of: playback.accountEpoch) {
            focusedFolder = nil
            expandedFolders.removeAll()
        }
    }

    @ViewBuilder
    private var emptyLibraryContent: some View {
        if isLoading {
            ProgressView("Loading playlists")
                .controlSize(.small)
                .font(.caption)
        } else if let error {
            SidebarLibraryPlaceholder(
                title: "Couldn't load playlists", message: error,
                canRetry: playback.isConnected && !isRefreshing, retry: retry)
        } else if hasLoaded {
            SidebarLibraryPlaceholder(
                title: isCached ? "No saved playlists" : "No playlists yet",
                message: isCached
                    ? (isRefreshing ? "Checking Spotify for updates…" : "This saved library may be out of date.")
                    : "Playlists you save in Spotify appear here.")
        }
    }

    private var libraryStatus: String {
        if let error { return isCached ? "Showing saved playlists. \(error)" : error }
        return isRefreshing ? "Showing saved playlists while updating" : "Saved playlists may be out of date"
    }

    private var nativeSelection: Binding<Set<String>> {
        Binding(
            get: { selectedRowID.map { [$0] } ?? [] },
            set: { ids in
                guard ids.count == 1, let row = visibleRows.first(where: { ids.contains($0.id) }) else { return }
                if let playlist = row.node.playlist {
                    focusedFolder = nil
                    selection = .playlist(playlist.uri)
                } else {
                    focusedFolder = FolderFocus(id: row.id, route: selection)
                }
            }
        )
    }

    private var selectedRowID: String? {
        if let focusedFolder, focusedFolder.route == selection { return focusedFolder.id }
        if case let .playlist(uri) = selection { return uri }
        return nil
    }

    private var visibleRows: [PlaylistLibraryNode.VisibleRow] {
        PlaylistLibraryNode.visibleRows(library, expanded: expandedFolders)
    }

    private var nativeRows: [NativeOccurrenceListRow] {
        visibleRows.map { row in
            NativeOccurrenceListRow(
                id: row.id, height: 64,
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
                playlist: playlist, isSelected: selectedRowID == row.id, playback: playback
            )
        } else {
            SidebarFolderRow(
                node: row.node, isExpanded: expandedFolders.contains(row.id), isSelected: selectedRowID == row.id
            ) {
                toggleFolder(row.id)
            }
        }
    }

    private func toggleFolder(_ id: String) {
        guard visibleRows.contains(where: { $0.id == id && $0.node.children != nil }) else { return }
        focusedFolder = FolderFocus(id: id, route: selection)
        if !expandedFolders.insert(id).inserted { expandedFolders.remove(id) }
    }

    /// Remember the route at the moment of folder focus so a later navigation takes precedence,
    /// without an asynchronous route notification clearing a newer native folder selection.
    private struct FolderFocus {
        let id: String
        let route: SidebarSelection?
    }
}

private struct SidebarLibraryPlaceholder: View {
    let title: String
    let message: String
    var canRetry = false
    var retry: (() async -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SpottyPalette.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(SpottyPalette.textSecondary)
            if let retry {
                CatalogCardButton {
                    Task { await retry() }
                } label: { _ in
                    Text("Try Again")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white, in: Capsule())
                        .opacity(canRetry ? 1 : 0.5)
                }
                .disabled(!canRetry)
                .pointingHandCursor(enabled: canRetry)
                .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }
}

private struct SidebarFolderRow: View {
    let node: PlaylistLibraryNode
    let isExpanded: Bool
    let isSelected: Bool
    let toggle: () -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var selectedBackground: Color {
        controlActiveState == .inactive ? SpottyPalette.selectedControlInactive : SpottyPalette.selectedControl
    }

    var body: some View {
        CatalogCardButton(action: toggle) { _ in
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
            .background(
                isSelected ? selectedBackground : (isHovering ? SpottyPalette.navigationControl : .clear),
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .pointingHandCursor(isHovering: $isHovering)
        .onDisappear { isHovering = false }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                let action = playback.action(for: playlist, behavior: .activateSelection)
                CatalogArtworkPlaybackButton(action: action, isPointerRevealed: isHovering) { showsPause, isFocused in
                    ZStack {
                        Color.black.opacity(0.5)
                        TransportSymbol(kind: showsPause ? .pause : .play)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .opacity(isHovering || isFocused ? (action.isEnabled ? 1 : 0.4) : 0)
                }
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
            (playlist.subtitle.isEmpty ? "Playlist" : playlist.subtitle) + (isPlaying ? ", Active playlist" : "")
        )
        .help(playlist.title)
    }
}
