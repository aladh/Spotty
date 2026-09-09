import SpottyDomain
import SwiftUI

struct CatalogTextLink: View {
    let title: String
    let item: CatalogItem?
    var color: Color = SpottyPalette.textSecondary
    var searchQuery = ""
    let onSelect: ((CatalogItem) -> Void)?
    @State private var isHovering = false

    var body: some View {
        if let item, let onSelect {
            Button {
                onSelect(item)
            } label: {
                Text(PlaylistSearch(searchQuery).highlighted(title))
                    .underline(isHovering)
                    .foregroundStyle(isHovering ? SpottyPalette.textPrimary : color)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .pointingHandCursor(isHovering: $isHovering)
            .onDisappear { isHovering = false }
            .accessibilityAddTraits(.isLink)
            .help("Open \(title)")
        } else {
            Text(PlaylistSearch(searchQuery).highlighted(title)).foregroundStyle(color).lineLimit(1)
        }
    }
}

struct CatalogArtistLinks: View {
    let artists: [CatalogItem]
    let fallback: String
    var color: Color = SpottyPalette.textSecondary
    var searchQuery = ""
    let onSelect: ((CatalogItem) -> Void)?

    var body: some View {
        if artists.isEmpty {
            Text(PlaylistSearch(searchQuery).highlighted(fallback)).foregroundStyle(color).lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                    if index > 0 { Text(", ").foregroundStyle(color) }
                    CatalogTextLink(
                        title: artist.title, item: artist, color: color,
                        searchQuery: searchQuery, onSelect: onSelect)
                }
            }
        }
    }
}

extension View {
    func pointingHandCursor(enabled: Bool = true, isHovering: Binding<Bool>? = nil) -> some View {
        modifier(PointingHandCursor(enabled: enabled, isHovering: isHovering))
    }
}

private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    let isHovering: Binding<Bool>?
    @State private var isInside = false

    func body(content: Content) -> some View {
        content
            .pointerStyle(enabled ? .link : nil)
            .onHover { inside in
                isInside = inside
                isHovering?.wrappedValue = enabled && inside
            }
            .onChange(of: enabled) { _, enabled in
                isHovering?.wrappedValue = enabled && isInside
            }
            .onDisappear {
                isInside = false
                isHovering?.wrappedValue = false
            }
    }
}
