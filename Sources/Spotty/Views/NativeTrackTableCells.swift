import SpottyDomain
import SwiftUI

enum NativeTrackColumn: String, CaseIterable {
    case index
    case title
    case artist
    case album
    case dateAdded
    case popularity
    case bpm
    case key
    case duration

    var title: String {
        switch self {
        case .index: "#"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .dateAdded: "Date added"
        case .popularity: "Popularity"
        case .bpm: "BPM"
        case .key: "Key"
        case .duration: "Time"
        }
    }

    var comparator: KeyPathComparator<TrackTableRow>? {
        switch self {
        case .index: nil
        case .title: KeyPathComparator(\TrackTableRow.title)
        case .artist: KeyPathComparator(\TrackTableRow.artist)
        case .album: KeyPathComparator(\TrackTableRow.album)
        case .dateAdded: KeyPathComparator(\TrackTableRow.dateAddedSortValue)
        case .popularity: KeyPathComparator(\TrackTableRow.popularitySortValue)
        case .bpm: KeyPathComparator(\TrackTableRow.bpmSortValue)
        case .key: KeyPathComparator(\TrackTableRow.keySortValue)
        case .duration: KeyPathComparator(\TrackTableRow.duration)
        }
    }

    static func columns(for variant: TrackTableVariant) -> [Self] {
        switch variant {
        case .catalog: [.title, .artist, .album, .popularity, .bpm, .key, .duration]
        case .playlist: [.index, .title, .album, .dateAdded, .duration]
        }
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
    let metadata: CatalogMetadataRepository
    let searchQuery: String
    let onSelect: ((CatalogItem) -> Void)?

    var body: some View {
        content
            .font(.system(size: 14))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch column {
        case .index: .trailing
        case .duration where variant == .playlist: .center
        default: .leading
        }
    }

    @ViewBuilder
    private var content: some View {
        switch column {
        case .index:
            indexCell
        case .title:
            if variant == .playlist {
                playlistTitleCell
            } else {
                catalogTitleCell
            }
        case .artist:
            Text(row.track.artist)
                .foregroundStyle(SpottyPalette.textSecondary)
        case .album:
            if variant == .playlist {
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
        case .popularity:
            Text(metadata.trackAttributes[row.track.uri]?.popularity.map(String.init) ?? "—")
                .foregroundStyle(SpottyPalette.dataText)
        case .bpm:
            let text = metadata.trackAttributes[row.track.uri]?.bpm.map(String.init) ?? "—"
            Text(text)
                .monospacedDigit()
                .foregroundStyle(SpottyPalette.dataText)
                .accessibilityLabel("BPM")
                .accessibilityValue(text)
        case .key:
            Text(metadata.trackAttributes[row.track.uri]?.key ?? "—")
                .foregroundStyle(SpottyPalette.dataText)
        case .duration:
            Text(
                variant == .playlist
                    ? formatCatalogDuration(row.track.duration) : formatDuration(row.track.duration)
            )
            .monospacedDigit()
            .foregroundStyle(SpottyPalette.dataText)
        }
    }

    private var indexCell: some View {
        let indicator = playback.currentTrackIndicator
        let isCurrent = indicator.trackURI == row.track.uri
        let currentForeground = isSelected ? SpottyPalette.textPrimary : SpottyPalette.mediaGreen

        return Group {
            if isCurrent && indicator.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(currentForeground)
            } else {
                Text(String(position))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? currentForeground : SpottyPalette.dataText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(
            isCurrent ? "Current track, track \(position) of \(total)" : "Track \(position) of \(total)"
        )
    }

    private var playlistTitleCell: some View {
        let isCurrent = playback.currentTrackIndicator.trackURI == row.track.uri
        let titleForeground = isCurrent && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textPrimary
        let artistForeground = isCurrent && !isSelected ? SpottyPalette.mediaGreen : SpottyPalette.textSecondary

        return HStack(alignment: .center, spacing: 12) {
            RemoteArtwork(url: row.track.artworkURL, kind: .track, cornerRadius: 4)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(PlaylistSearch(searchQuery).highlighted(row.track.title))
                    .font(.system(size: 16))
                    .foregroundStyle(titleForeground)
                    .lineLimit(1)
                CatalogArtistLinks(
                    artists: row.track.artists, fallback: row.track.artist, color: artistForeground,
                    searchQuery: searchQuery, onSelect: onSelect
                )
                .font(.system(size: 14))
            }
        }
        .accessibilityElement(children: .contain)
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
