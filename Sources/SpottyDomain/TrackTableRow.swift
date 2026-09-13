//
//  TrackTableRow.swift
//  Spotty
//

import Foundation

public struct TrackTableRow: Identifiable, Equatable, Sendable {
    public let track: CatalogTrack
    public let sourceIndex: Int

    public var id: CatalogTrack.ID { track.id }
    public var title: String { track.title }
    public var artist: String { track.artist }
    public var album: String { track.album }
    public var dateAddedSortValue: Date { track.dateAddedSortValue }
    public var duration: TimeInterval { track.duration }

    init(track: CatalogTrack, sourceIndex: Int) {
        self.track = track
        self.sourceIndex = sourceIndex
    }
}

extension KeyPathComparator where Compared == TrackTableRow {
    var isDateAdded: Bool {
        self == KeyPathComparator(\TrackTableRow.dateAddedSortValue, order: order)
    }
}
