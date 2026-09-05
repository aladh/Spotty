import SpottyDomain
import SwiftUI

struct PlaylistSearch {
    let query: String

    init(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(_ track: CatalogTrack) -> Bool {
        query.isEmpty || [track.title, track.artist, track.album].contains { $0.localizedStandardContains(query) }
    }

    func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex,
            let match = text.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex)
        {
            if let lower = AttributedString.Index(match.lowerBound, within: result),
                let upper = AttributedString.Index(match.upperBound, within: result)
            {
                result[lower..<upper].backgroundColor = Color.blue
                result[lower..<upper].foregroundColor = Color.white
            }
            start = match.upperBound
        }
        return result
    }
}
