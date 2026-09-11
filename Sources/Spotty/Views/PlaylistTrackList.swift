import SpottyDomain
import SwiftUI

/// Playlist-specific list geometry and drawing; TrackTable owns shared selection and filtering.
struct PlaylistTrackList: View {
    let rows: [TrackTableRow]
    let playback: CatalogPlaybackAccess
    let searchQuery: String
    @Binding var selection: Set<CatalogTrack.ID>
    @Binding var sortOrder: [KeyPathComparator<TrackTableRow>]
    let onSelect: ((CatalogItem) -> Void)?
    let playlistHeader: AnyView?
    let compactPlaylistHeader: AnyView?
    @State private var playlistHeaderHeight: CGFloat = 0
    @State private var showsCompactHeader = false

    var body: some View {
        GeometryReader { geometry in playlistList(width: geometry.size.width) }
    }

    private func isCurrent(_ track: CatalogTrack) -> Bool {
        playback.currentTrackIndicator.trackURI == track.uri
    }

    private func playlistIndexCell(_ row: TrackTableRow, position: Int, total: Int) -> some View {
        let currentTrackIndicator = playback.currentTrackIndicator
        let isCurrentTrack = currentTrackIndicator.trackURI == row.track.uri
        let isSelected = selection.contains(row.id)
        let indexForeground: Color = isSelected ? SpottyPalette.textPrimary : SpottyPalette.mediaGreen

        return Group {
            if isCurrentTrack && currentTrackIndicator.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(indexForeground)
                    .accessibilityLabel("Current track, track \(position) of \(total)")
            } else if isCurrentTrack {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(indexForeground)
                    .accessibilityLabel("Current track, track \(position) of \(total)")
            } else {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(SpottyPalette.dataText)
                    .accessibilityLabel("Track \(position) of \(total)")
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, minHeight: CatalogLayout.playlistRowContentHeight, alignment: .trailing)
    }

    private func playlistTitleCell(_ track: CatalogTrack) -> some View {
        let isCurrentTrack = isCurrent(track)
        let isSelected = selection.contains(track.id)
        let titleForeground: Color =
            isCurrentTrack && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary
        let artistForeground: Color =
            isCurrentTrack && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textSecondary

        return HStack(alignment: .center, spacing: 12) {
            RemoteArtwork(
                url: track.artworkURL,
                kind: .track,
                cornerRadius: 4
            )
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(PlaylistSearch(searchQuery).highlighted(track.title))
                    .font(.system(size: 16))
                    .foregroundStyle(titleForeground)
                    .lineLimit(1)
                CatalogArtistLinks(
                    artists: track.artists, fallback: track.artist, color: artistForeground,
                    searchQuery: searchQuery, onSelect: onSelect
                )
                .font(.system(size: 14))
            }
        }
        .frame(maxWidth: .infinity, minHeight: CatalogLayout.playlistRowContentHeight, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func playlistList(width: CGFloat) -> some View {
        let indexWidth = max(24, CGFloat(String(max(1, rows.count)).count) * 9)
        let flexibleWidth = max(400, width - 48 - 176 - indexWidth)
        let titleWidth = flexibleWidth / 2
        let detailWidth = flexibleWidth / 4
        let columnHeader =
            HStack(spacing: 16) {
                Text("#").frame(width: indexWidth, alignment: .trailing)
                playlistColumnHeader("Title", index: 1, keyPath: \TrackTableRow.title)
                    .frame(width: titleWidth, alignment: .leading)
                playlistColumnHeader("Album", index: 2, keyPath: \TrackTableRow.album)
                    .frame(width: detailWidth, alignment: .leading)
                playlistColumnHeader("Date added", index: 3, keyPath: \TrackTableRow.dateAddedSortValue)
                    .frame(width: detailWidth, alignment: .leading)
                Button {
                    sortPlaylistColumn(4)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock").font(.system(size: 16))
                        if let comparator = sortOrder.first, comparator.keyPath == \TrackTableRow.duration {
                            Image(
                                systemName: comparator.order == .forward
                                    ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
                            )
                            .font(.system(size: 8))
                            .foregroundStyle(SpottyPalette.mediaGreen)
                        }
                    }
                    .frame(width: 80, alignment: .center)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by duration")
            }
            .font(.system(size: 14))
            .foregroundStyle(SpottyPalette.dataText)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .overlay(alignment: .bottom) { Color.white.opacity(0.1).frame(height: 1) }

            .padding(.horizontal, 24)
            .background(showsCompactHeader ? SpottyPalette.catalogCanvas : Color.clear)

        return List(selection: $selection) {
            if let playlistHeader {
                playlistHeader
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        playlistHeaderHeight = $0
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .background {
                        PlaylistScrollObserver(threshold: playlistHeaderHeight - 64) {
                            showsCompactHeader = $0
                        }
                    }
            }
            columnHeader
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .selectionDisabled()

            ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                HStack(spacing: 16) {
                    playlistIndexCell(row, position: offset + 1, total: rows.count).frame(width: indexWidth)
                    playlistTitleCell(row.track).frame(width: titleWidth, alignment: .leading)
                    CatalogTextLink(
                        title: row.track.album, item: row.track.albumItem,
                        color: SpottyPalette.dataText, searchQuery: searchQuery, onSelect: onSelect
                    )
                    .frame(width: detailWidth, alignment: .leading)
                    Text(formatPlaylistDateAdded(row.track.addedAt))
                        .foregroundStyle(SpottyPalette.dataText)
                        .lineLimit(1)
                        .frame(width: detailWidth, alignment: .leading)
                    Text(formatCatalogDuration(row.track.duration))
                        .foregroundStyle(SpottyPalette.dataText)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .center)
                }
                .frame(height: 40)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .modifier(PlaylistTrackRowHighlight(isSelected: selection.contains(row.id)))
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowSeparator(.hidden)
                .tag(row.id)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .top) {
            if showsCompactHeader, let compactPlaylistHeader {
                VStack(spacing: 0) {
                    compactPlaylistHeader
                    columnHeader
                }
            }
        }
    }

    private func playlistColumnHeader<Value>(
        _ title: String, index: Int, keyPath: KeyPath<TrackTableRow, Value> & Sendable
    ) -> some View {
        Button {
            sortPlaylistColumn(index)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                if let comparator = sortOrder.first, comparator.keyPath == keyPath {
                    Image(
                        systemName: comparator.order == .forward ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
                    )
                    .font(.system(size: 8))
                    .foregroundStyle(SpottyPalette.mediaGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
    }

    private func sortPlaylistColumn(_ index: Int) {
        let columns = [
            KeyPathComparator(\TrackTableRow.title),
            KeyPathComparator(\TrackTableRow.album),
            KeyPathComparator(\TrackTableRow.dateAddedSortValue),
            KeyPathComparator(\TrackTableRow.duration),
        ]
        guard (1...columns.count).contains(index) else { return }
        var comparator = columns[index - 1]
        if let current = sortOrder.first, current.keyPath == comparator.keyPath {
            comparator.order = current.order == .forward ? .reverse : .forward
        }
        sortOrder = [comparator]
    }

}

private struct PlaylistTrackRowHighlight: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(
                    isSelected ? (controlActiveState == .inactive ? 0.13 : 0.2) : (isHovering ? 0.1 : 0)),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .background { PlaylistSelectionAppearance() }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: if !isHovering { isHovering = true }
                case .ended: isHovering = false
                }
            }
            .onDisappear { isHovering = false }
    }
}
