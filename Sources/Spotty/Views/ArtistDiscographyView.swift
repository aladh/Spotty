import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI

struct ArtistDiscographyView: View {
    let item: CatalogItem
    let albums: DiscographyStore
    let playback: CatalogPlaybackAccess
    let playlistActions: TrackPlaylistActions?
    let onSelect: (CatalogItem) -> Void
    @Bindable var interactionState: CatalogRouteInteractionState
    @State private var trackProjection = DiscographyTrackProjection()

    private var artist: ArtistDetailStore { albums.artist }

    private struct GridConfiguration: Hashable {
        let artistURI: String
        let filter: ArtistReleaseFilter
        let sort: DiscographySort
    }

    private var releases: [CatalogItem] {
        DiscographyReleases.project(
            artist.releases, kinds: artist.releaseKinds, dates: artist.releaseDates,
            filter: interactionState.artistReleaseFilter, sort: interactionState.discographySort)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            CatalogContentState(
                isLoading: artist.isLoading || albums.artistURI != item.uri,
                isEmpty: releases.isEmpty, error: artist.error,
                loadingLabel: "Loading discography", errorTitle: "Couldn't load discography",
                retry: { await artist.load(item, force: true) }
            ) {
                EmptyState(icon: "square.stack", title: "No releases", message: "No releases match this filter.")
            } content: {
                if interactionState.discographyLayout == .grid {
                    ScrollView {
                        LazyVGrid(columns: MediaGridLayout.columns, spacing: 18) {
                            ForEach(releases) { release in
                                MediaCard(item: release, playback: playback) { onSelect(release) }
                            }
                        }
                        .padding(CatalogLayout.contentPadding)
                    }
                    .id(
                        GridConfiguration(
                            artistURI: item.uri, filter: interactionState.artistReleaseFilter,
                            sort: interactionState.discographySort))
                } else {
                    releaseList
                }
            }
        }
        .navigationTitle("\(item.title) — Discography")
        .catalogTask(id: item.uri, playback: playback) {
            albums.prepare(artistURI: item.uri)
            await artist.load(item)
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                onSelect(item)
            } label: {
                Text(artist.item?.title ?? item.title).font(.system(size: 24, weight: .bold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel("Open \(item.title)")
            Spacer(minLength: 0)
            Menu {
                Picker(
                    "Release type",
                    selection: Binding(
                        get: { interactionState.artistReleaseFilter },
                        set: {
                            resetPosition(); interactionState.artistReleaseFilter = $0
                        })
                ) {
                    ForEach(ArtistReleaseFilter.allCases, id: \.self) { filter in
                        Text(filter == .popular ? "All" : filter.rawValue).tag(filter)
                    }
                }
            } label: {
                menuLabel(
                    interactionState.artistReleaseFilter == .popular
                        ? "All" : interactionState.artistReleaseFilter.rawValue)
            }
            .fixedSize()
            .accessibilityLabel("Release type")
            Menu {
                Picker(
                    "Sort by",
                    selection: Binding(
                        get: { interactionState.discographySort },
                        set: {
                            resetPosition(); interactionState.discographySort = $0
                        })
                ) {
                    ForEach(DiscographySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Picker("View as", selection: $interactionState.discographyLayout) {
                    ForEach(DiscographyLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                menuLabel(
                    interactionState.discographySort.rawValue,
                    symbol: interactionState.discographyLayout == .list ? "list.bullet" : "square.grid.2x2")
            }
            .fixedSize()
            .accessibilityLabel("Discography sort and view")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.vertical, 24)
    }

    private func menuLabel(_ title: String, symbol: String = "chevron.down") -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Image(systemName: symbol)
        }
        .font(.system(size: 14))
        .foregroundStyle(SpottyPalette.textSecondary)
        .fixedSize()
    }

    private var releaseList: some View {
        let sections = trackProjection.sections(releases, albums: albums.albums)
        let trackRows = sections.flatMap { release, rows in
            rows.map { (id: rowID(release, $0), track: $0.track) }
        }
        let loadedSelections = Dictionary(
            uniqueKeysWithValues: sections.compactMap { release, rows -> (String, Set<String>)? in
                guard albums.albums[release.uri]?.hasLoadedContent == true else { return nil }
                return (release.uri, Set(rows.map { rowID(release, $0) }))
            })
        let selectedTracks: (Set<String>) -> [CatalogTrack] = { ids in
            trackRows.filter { ids.contains($0.id) }.map(\.track)
        }
        let rows = sections.flatMap { release, tracks in
            let album = albums.albums[release.uri]
            var rows = [
                NativeOccurrenceListRow(
                    id: release.uri, height: 216, isSelectable: false,
                    content: AnyView(
                        DiscographyReleaseHeader(
                            item: release, album: album, playback: playback, onSelect: onSelect,
                            retry: { await albums.load(release, artistURI: item.uri) }
                        )
                        .catalogTask(id: "\(item.uri):\(release.uri)", playback: playback) {
                            await albums.load(release, artistURI: item.uri)
                        }))
            ]
            rows += tracks.map { row in
                NativeOccurrenceListRow(
                    id: rowID(release, row), height: 56, drawsHover: true,
                    content: AnyView(
                        DiscographyTrackRow(
                            row: row, total: tracks.count, playback: playback,
                            isSelected: interactionState.selection.contains(rowID(release, row)),
                            playCount: album?.playCounts[row.track.uri], onSelect: onSelect)))
            }
            return rows
        }
        return NativeOccurrenceList(
            rows: rows, selection: $interactionState.selection, preservesVisibleAnchor: true,
            accessibilityLabel: "Discography", scrollState: interactionState.discographyScroll,
            primaryAction: { ids in
                let selected = selectedTracks(ids)
                if selected.count == 1, let track = selected.first, playback.canStartPlayback {
                    playback.playTrack(track)
                }
            },
            contextMenu: { ids in
                trackSelectionMenu(tracks: selectedTracks(ids), playback: playback, playlistActions: playlistActions)
            }
        )
        .onChange(of: loadedSelections, initial: true) { _, loaded in
            guard albums.artistURI == item.uri, artist.item?.uri == item.uri else { return }
            // An unloaded or evicted album is not evidence that its selected tracks were removed.
            interactionState.selection = interactionState.selection.filter { id in
                loaded.allSatisfy { uri, ids in !id.hasPrefix("\(uri):") || ids.contains(id) }
            }
        }
    }

    private func rowID(_ release: CatalogItem, _ row: TrackTableRow) -> String {
        "\(release.uri):\(row.id)"
    }

    private func resetPosition() {
        interactionState.selection = []
        interactionState.discographyScroll.offset = 0
    }
}

private struct DiscographyReleaseHeader: View {
    let item: CatalogItem
    let album: AlbumDetailStore?
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                Button {
                    onSelect(item)
                } label: {
                    RemoteArtwork(url: item.artworkURL, kind: .album, cornerRadius: 4)
                        .frame(width: 132, height: 132)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel("Open \(item.title)")
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        onSelect(item)
                    } label: {
                        Text(item.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    Text(metadata).font(.system(size: 14)).foregroundStyle(SpottyPalette.textSecondary)
                    HStack(spacing: 16) {
                        Button {
                            playback.playURI(item.uri)
                        } label: {
                            TransportSymbol(kind: .play).frame(width: 14, height: 14)
                                .foregroundStyle(.black).frame(width: 32, height: 32).background(.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!playback.canStartPlayback)
                        .accessibilityLabel("Play \(item.title)")
                        if let album, let error = album.error {
                            Button("Try again") { Task { await retry() } }.help(error)
                        } else if album == nil || album?.isLoading == true {
                            ProgressView().controlSize(.small).accessibilityLabel("Loading \(item.title)")
                        } else if album?.hasLoadedContent == true, album?.tracks.isEmpty == true {
                            Text("No tracks").font(.system(size: 14)).foregroundStyle(SpottyPalette.textSecondary)
                        } else if album?.isShowingCachedContent == true {
                            Text("Possibly out of date").font(.system(size: 14)).foregroundStyle(
                                SpottyPalette.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 32)
            .padding(.bottom, 16)
            GeometryReader { geometry in
                NativeTrackColumnHeaders(
                    columns: NativeTrackColumn.columns(for: .album),
                    widths: NativeTrackColumn.albumWidths(
                        tableWidth: geometry.size.width, rowCount: album?.tracks.count ?? 0),
                    sortOrder: [], sort: nil)
            }.frame(height: 36)
        }
        .padding(.horizontal, CatalogLayout.contentPadding)
    }

    private var metadata: String {
        var parts = [item.subtitle]
        if let album, album.hasLoadedContent {
            parts.append("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

private struct DiscographyTrackRow: View {
    let row: TrackTableRow
    let total: Int
    let playback: CatalogPlaybackAccess
    let isSelected: Bool
    let playCount: Int64?
    let onSelect: (CatalogItem) -> Void

    var body: some View {
        GeometryReader { geometry in
            let widths = NativeTrackColumn.albumWidths(tableWidth: geometry.size.width, rowCount: total)
            HStack(spacing: 0) {
                ForEach(Array(zip(NativeTrackColumn.columns(for: .album), widths)).filter { $0.1 > 0 }, id: \.0) {
                    column, width in
                    NativeTrackCell(
                        row: row, column: column, position: row.sourceIndex + 1, total: total, variant: .album,
                        isSelected: isSelected, playback: playback, searchQuery: "", onSelect: onSelect,
                        playCount: playCount
                    )
                    .padding(.horizontal, 8).frame(width: width, height: 56)
                }
            }
        }
        .padding(.horizontal, CatalogLayout.contentPadding)
    }
}

/// Selection and menu updates reuse row formatting until an album collection changes.
@MainActor
private final class DiscographyTrackProjection {
    private var caches: [String: TrackTableDisplayCache] = [:]

    func sections(_ releases: [CatalogItem], albums: [String: AlbumDetailStore]) -> [(CatalogItem, [TrackTableRow])] {
        caches = caches.filter { albums[$0.key] != nil }
        return releases.map { release in
            guard let album = albums[release.uri] else { return (release, []) }
            var cache = caches[release.uri] ?? TrackTableDisplayCache()
            if cache.update(album.trackCollection, sortOrder: []) { caches[release.uri] = cache }
            return (release, cache.rows)
        }
    }
}
