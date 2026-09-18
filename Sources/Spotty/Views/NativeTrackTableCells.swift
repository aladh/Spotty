import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI

enum NativeTrackColumn: String, CaseIterable {
    case index
    case title
    case artist
    case album
    case dateAdded
    case duration
    case playCount

    var title: String {
        switch self {
        case .index: "#"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .dateAdded: "Date added"
        case .duration: "Time"
        case .playCount: "Plays"
        }
    }

    var comparator: KeyPathComparator<TrackTableRow>? {
        switch self {
        case .index, .playCount: nil
        case .title: KeyPathComparator(\TrackTableRow.title)
        case .artist: KeyPathComparator(\TrackTableRow.artist)
        case .album: KeyPathComparator(\TrackTableRow.album)
        case .dateAdded: KeyPathComparator(\TrackTableRow.dateAddedSortValue)
        case .duration: KeyPathComparator(\TrackTableRow.duration)
        }
    }

    static func columns(for variant: TrackTableVariant) -> [Self] {
        switch variant {
        case .catalog: [.title, .artist, .album, .duration]
        case .playlist: [.index, .title, .album, .dateAdded, .duration]
        case .album: [.index, .title, .playCount, .duration]
        case .artist: [.index, .title, .playCount, .duration]
        case .search: [.index, .title, .album, .duration]
        }
    }

    static func albumWidths(tableWidth: CGFloat, rowCount: Int) -> [CGFloat] {
        let index = max(24, CGFloat(String(max(1, rowCount)).count) * 9) + 24
        let plays: CGFloat = tableWidth >= 520 ? 120 : 0
        return [index, tableWidth - index - 104 - plays, plays, 104]
    }
}

/// Hosted cell content reads only the observable facts that its column displays.
/// The native table owns row selection, sizing, and reuse.
struct NativeTrackCell: View {
    let row: TrackTableRow
    let column: NativeTrackColumn
    let position: Int
    let total: Int
    let variant: TrackTableVariant
    let isSelected: Bool
    let playback: CatalogPlaybackAccess
    let searchQuery: String
    let onSelect: ((CatalogItem) -> Void)?
    var artistTrack: CatalogArtistPopularTrack? = nil
    var playCount: Int64? = nil
    @State private var indexHovered = false

    private var isRowPlayable: Bool { artistTrack?.isPlayable != false }

    var body: some View {
        content
            .font(.system(size: 14))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .opacity(isRowPlayable ? 1 : 0.45)
    }

    private var alignment: Alignment {
        switch column {
        case .index: .trailing
        case .duration where variant != .catalog: .center
        default: .leading
        }
    }

    @ViewBuilder
    private var content: some View {
        switch column {
        case .index:
            indexCell
        case .title:
            if variant != .catalog {
                detailTitleCell
            } else {
                catalogTitleCell
            }
        case .artist:
            Text(row.track.artist)
                .foregroundStyle(SpottyPalette.textSecondary)
        case .album:
            if variant == .playlist || variant == .search {
                CatalogTextLink(
                    title: row.track.album, item: row.track.albumItem,
                    color: SpottyPalette.dataText, searchQuery: searchQuery, onSelect: onSelect
                )
            } else {
                Text(row.track.album)
                    .foregroundStyle(SpottyPalette.textSecondary)
            }
        case .dateAdded:
            Text(formatPlaylistDateAdded(row.track.addedAt))
                .foregroundStyle(SpottyPalette.dataText)
        case .duration:
            Text(
                variant == .playlist || variant == .search
                    ? formatCatalogDuration(row.track.duration) : formatDuration(row.track.duration)
            )
            .monospacedDigit()
            .foregroundStyle(SpottyPalette.dataText)
        case .playCount:
            if let count = playCount {
                Text(count.formatted()).foregroundStyle(SpottyPalette.dataText)
                    .accessibilityLabel("\(count.formatted()) plays")
            }
        }
    }

    private var indexCell: some View {
        let indicator = playback.currentTrackIndicator
        let isCurrent = indicator.trackURI == row.track.uri
        let currentForeground = isSelected ? SpottyPalette.textPrimary : SpottyPalette.mediaGreen
        let canActivate = playback.canActivateTrack(row.track, isPlayable: isRowPlayable)
        let showsPause = isCurrent && indicator.isPlaying

        return Button {
            playback.activateTrack(row.track, isPlayable: isRowPlayable)
        } label: {
            Group {
                if indexHovered && canActivate {
                    TransportSymbol(kind: showsPause ? .pause : .play)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(SpottyPalette.textPrimary)
                } else if showsPause {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(currentForeground)
                } else {
                    Text(String(position))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? currentForeground : SpottyPalette.dataText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canActivate)
        .pointingHandCursor(enabled: canActivate)
        .onHover { indexHovered = $0 }
        .accessibilityLabel("\(showsPause ? "Pause" : "Play") \(row.track.title)")
        .accessibilityValue(
            (isCurrent ? "Current track, track \(position) of \(total)" : "Track \(position) of \(total)")
                + (isRowPlayable ? "" : ", unavailable")
        )
    }

    private var detailTitleCell: some View {
        let isCurrent = playback.currentTrackIndicator.trackURI == row.track.uri
        let titleForeground = isCurrent && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary
        let artistForeground = isCurrent && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textSecondary

        return HStack(alignment: .center, spacing: 12) {
            if variant == .playlist || variant == .artist || variant == .search {
                RemoteArtwork(url: row.track.artworkURL, kind: .track, cornerRadius: 4)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(PlaylistSearch(searchQuery).highlighted(row.track.title))
                    .font(.system(size: 16))
                    .foregroundStyle(titleForeground)
                    .lineLimit(1)
                    .accessibilityLabel(
                        isRowPlayable ? row.track.title : "\(row.track.title), unavailable")
                if variant != .artist {
                    CatalogArtistLinks(
                        artists: row.track.artists, fallback: row.track.artist, color: artistForeground,
                        searchQuery: searchQuery, onSelect: onSelect
                    )
                    .font(.system(size: 14))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isRowPlayable ? "" : "Unavailable")
    }

    private var catalogTitleCell: some View {
        let isCurrent = playback.currentTrackIndicator.trackURI == row.track.uri
        let foreground = isCurrent && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary

        return HStack(spacing: 6) {
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .accessibilityLabel("Current track")
            }
            Text(row.track.title)
                .font(.system(size: 16))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
    }
}
