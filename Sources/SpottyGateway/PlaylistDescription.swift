import SpottyDomain
import Foundation
import SpottyRuntimeContracts

/// Converts Spotify's small HTML description fragment into safe, lightweight display text.
///
/// Playlist descriptions commonly contain artist links and simple line breaks. Rendering that
/// source verbatim leaks markup into SwiftUI, while creating an HTML document just to strip it
/// adds unnecessary AppKit/WebKit work. This deliberately bounded conversion keeps the visible
/// text and the handful of entities Spotify emits.
enum PlaylistDescription {
    nonisolated static func plainText(from source: String) -> String {
        guard !source.isEmpty else { return "" }

        var result =
            source
            .replacingOccurrences(
                of: #"<br\s*/?>|</p\s*>|</div\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<[^>]+>"#,
                with: "",
                options: .regularExpression
            )

        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        return
            result
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
