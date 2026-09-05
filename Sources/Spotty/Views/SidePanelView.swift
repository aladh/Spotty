//
//  SidePanelView.swift
//  Spotty
//
//  The right-hand playback panel: the play queue and the recently played list.
//

import SpottyDomain
import SwiftUI

/// Restarts queue hydration when launch-time Connect ordering arrives after the account becomes
/// ready. Queue snapshots produced by that hydration deliberately do not change this identity,
/// avoiding a redundant second refresh while ordering and metadata converge.
struct SidePanelQueueRefreshIdentity: Equatable {
    let isConnected: Bool
    let currentTrackURI: String
    let connectOrderingVersion: UInt64
}

struct SidePanelView: View {
    let metadata: CatalogMetadataRepository
    let player: PlaybackStore
    let panel: PlaybackPanel
    let onSelect: (CatalogItem) -> Void
    let onClose: () -> Void

    @State private var tab: Tab = .queue
    @State private var upcomingSelection: Set<QueueEntry.ID> = []

    enum Tab: String, CaseIterable {
        case queue = "Queue"
        case history = "Recently played"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if panel == .connect {
                    ConnectPanelContent(player: player)
                } else {
                    switch tab {
                    case .queue: queueList
                    case .history: historyList
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { SpottyPalette.catalogCanvas.ignoresSafeArea() }
        .task(id: queueRefreshIdentity) {
            guard player.isConnected && panel == .queue else {
                player.cancelQueueRefresh()
                return
            }
            player.refreshQueue()
        }
        .onDisappear { player.cancelQueueRefresh() }
    }

    private var queueRefreshIdentity: SidePanelQueueRefreshIdentity {
        SidePanelQueueRefreshIdentity(
            isConnected: player.isConnected && panel == .queue,
            currentTrackURI: player.trackURI,
            connectOrderingVersion: player.queueInspectorOrderingVersion
        )
    }

    private var header: some View {
        HStack(spacing: 16) {
            if panel == .connect {
                Text("Connect")
                    .font(.system(size: 16, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            } else {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(tab == item ? SpottyPalette.textPrimary : SpottyPalette.textSecondary)
                            .fixedSize()
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if tab == item {
                                    Rectangle().fill(SpottyPalette.mediaGreen).frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }

            }
            Spacer(minLength: 0)

            Button("Close sidebar", systemImage: "xmark") {
                onClose()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(Color(white: 0.7))
            .frame(width: 32, height: 32)
            .help("Close sidebar")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    // MARK: - Queue

    @ViewBuilder
    private var queueList: some View {
        if !player.hasCurrentTrack && player.queueNextEntries.isEmpty {
            EmptyState(
                icon: "list.bullet.rectangle",
                title: "Nothing queued",
                message: "Play something, or use a track's context menu to add it to the queue."
            )
        } else {
            List(selection: $upcomingSelection) {
                if player.hasCurrentTrack {
                    railSectionHeader("Now playing")
                    CurrentTrackRow(player: player, metadata: metadata, onSelect: onSelect)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                if !player.queueNextEntries.isEmpty {
                    ForEach(Array(player.queueNextEntries.enumerated()), id: \.element.id) { index, entry in
                        if index == 0 || queueHeading(entry) != queueHeading(player.queueNextEntries[index - 1]) {
                            if queueHeading(entry) == "Next up", let playlist = queuePlaylist {
                                railSectionHeader {
                                    QueuePlaylistHeading(playlist: playlist, action: { onSelect(playlist) })
                                }
                            } else {
                                railSectionHeader(queueHeading(entry))
                            }
                        }
                        QueueUpcomingRow(entry: entry, metadata: metadata, player: player, onSelect: onSelect)
                            .tag(entry.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSeparator(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .contextMenu(forSelectionType: QueueEntry.ID.self) { selectedIDs in
                let selected = QueueMutationSelection.orderedUpcoming(
                    selectedIDs: selectedIDs,
                    in: player.queueNextEntries
                )
                if selected.count == 1, let entry = selected.first {
                    Button("Play", systemImage: "play.fill") {
                        player.play(uri: entry.uri)
                    }
                    .disabled(!player.canStartPlayback)
                }
                if !selected.isEmpty {
                    Button("Remove from Queue", role: .destructive) {
                        player.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
                    }
                    .disabled(!player.canRemoveUpcomingQueue(selectedIDs: selectedIDs))
                }
            } primaryAction: { selectedIDs in
                let selected = QueueMutationSelection.orderedUpcoming(
                    selectedIDs: selectedIDs,
                    in: player.queueNextEntries
                )
                guard selected.count == 1, let entry = selected.first else { return }
                guard player.canStartPlayback else { return }
                player.play(uri: entry.uri)
            }
            .onDeleteCommand {
                let selectedCount = QueueMutationSelection.orderedUpcoming(
                    selectedIDs: upcomingSelection,
                    in: player.queueNextEntries
                ).count
                guard
                    QueueMutationSelection.keyboardCommand(
                        deleteOrBackspace: true,
                        selectedUpcomingCount: selectedCount,
                        isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: upcomingSelection)
                    ) == .removeUpcomingOccurrences
                else {
                    return
                }
                player.removeUpcomingQueueOccurrences(selectedIDs: upcomingSelection)
            }
            .onChange(of: player.queueNextEntries.map(\.id), initial: true) { _, ids in
                upcomingSelection.formIntersection(Set(ids))
            }
            .accessibilityLabel("Queue")
        }
    }

    private func queueHeading(_ entry: QueueEntry) -> String {
        if entry.provider.contains("queue") { return "Next in queue" }
        if entry.provider.contains("autoplay") { return "Recommended" }
        return "Next up"
    }

    private func railSectionHeader(_ title: String) -> some View {
        railSectionHeader { Text(title) }
    }

    private var queuePlaylist: CatalogItem? {
        guard let uri = player.state.playbackContextURI,
            let item = metadata.knownItem(for: uri), item.kind == .playlist
        else { return nil }
        return item
    }

    private func railSectionHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .accessibilityElement(children: .contain)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(SpottyPalette.textPrimary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(SpottyPalette.catalogCanvas)
            .listRowInsets(EdgeInsets(top: 16, leading: 8, bottom: 8, trailing: 8))
            .listRowSeparator(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
    }

    // MARK: - History

    @ViewBuilder
    private var historyList: some View {
        if player.history.entries.isEmpty {
            EmptyState(
                icon: "clock.arrow.circlepath",
                title: "No listening history yet",
                message: "Tracks you play will appear here."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(player.history.entries) { entry in
                        HistoryRow(entry: entry) {
                            player.play(uri: entry.uri)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
        }
    }
}

private struct QueuePlaylistHeading: View {
    let playlist: CatalogItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Next from:").fixedSize()
            Button(action: action) {
                Text(playlist.title)
                    .underline(isHovering)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .pointingHandCursor(isHovering: $isHovering)
            .onDisappear { isHovering = false }
            .accessibilityAddTraits(.isLink)
            .help("Open \(playlist.title)")
        }
    }
}

/// One selectable upcoming queue row. Playback is Return/double-click via the list
/// primary action or the explicit artwork button; clicking the row still selects it.
private struct QueueUpcomingRow: View {
    let entry: QueueEntry
    let metadata: CatalogMetadataRepository
    let player: PlaybackStore
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        let info = metadata.displayInfo(for: entry.uri)
        QueueTrackRow(
            title: info.title,
            artist: metadata.knownTrack(for: entry.uri) == nil && metadata.knownItem(for: entry.uri) == nil
                ? entry.sourceLabel : info.artist,
            artists: metadata.knownTrack(for: entry.uri)?.artists ?? [],
            onSelect: onSelect,
            artworkURL: metadata.knownTrack(for: entry.uri)?.artworkURL,
            duration: metadata.knownTrack(for: entry.uri)?.duration,
            isCurrent: false,
            showsPause: false,
            canPlay: player.canStartPlayback,
            play: { player.play(uri: entry.uri) }
        )
    }
}

private struct QueueTrackRow: View {
    let title: String
    let artist: String
    let artists: [CatalogItem]
    let onSelect: (CatalogItem) -> Void
    let artworkURL: URL?
    let duration: TimeInterval?
    let isCurrent: Bool
    let showsPause: Bool
    let canPlay: Bool
    let play: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(url: artworkURL, kind: .track, cornerRadius: 4, pointSize: 48)
                .frame(width: 48, height: 48)
                .overlay {
                    Button(action: play) {
                        ZStack {
                            Color.black.opacity(0.5)
                            Image(systemName: showsPause ? "pause.fill" : "play.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPlay)
                    .pointingHandCursor(enabled: canPlay)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityLabel("\(showsPause ? "Pause" : "Play") \(title)")
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(isCurrent ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary)
                    .lineLimit(1)
                CatalogArtistLinks(
                    artists: artists, fallback: artist,
                    color: isHovering ? SpottyPalette.textPrimary : SpottyPalette.textSecondary, onSelect: onSelect
                )
                .font(.system(size: 14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(8)
        .contentShape(Rectangle())
        .background(isHovering ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .pointingHandCursor(isHovering: $isHovering)
        .onDisappear { isHovering = false }
        .accessibilityElement(children: .contain)
        .accessibilityValue(duration.map(formatPlaylistDuration) ?? "")
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let action: () -> Void

    @State private var isHovering = false

    private var relativeTime: String {
        entry.playedAt.formatted(.relative(presentation: .named))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RemoteArtwork(url: entry.artworkURL, kind: .track, cornerRadius: 4, pointSize: 48)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 16))
                        .lineLimit(1)
                    Text(entry.artist)
                        .font(.system(size: 14))
                        .foregroundStyle(SpottyPalette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                SpottyPalette.historySurface(isHovering: isHovering),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .hoverSurface(isHovering: $isHovering)
        .help("Play \(entry.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Play \(entry.title) by \(entry.artist)")
        .accessibilityValue("Played \(relativeTime)")
    }
}

/// The current track card at the top of the queue tab.
private struct CurrentTrackRow: View {
    let player: PlaybackStore
    let metadata: CatalogMetadataRepository
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        QueueTrackRow(
            title: player.displayedTrackTitle,
            artist: player.displayedArtistName,
            artists: metadata.knownTrack(for: player.trackURI)?.artists ?? [],
            onSelect: onSelect,
            artworkURL: player.displayedArtworkURL,
            duration: player.duration,
            isCurrent: true,
            showsPause: player.showsPauseControl,
            canPlay: player.canTogglePlayback,
            play: player.togglePlayback
        )
    }
}
