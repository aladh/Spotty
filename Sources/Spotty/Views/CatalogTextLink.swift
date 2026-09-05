import AppKit
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

@MainActor
private final class PointingHandRegion {
    var parent: PointingHandRegion?
    var isInside = false
    var points = false

    var hasPointingCursor: Bool { points || (parent?.hasPointingCursor ?? false) }
}

private extension EnvironmentValues {
    @Entry var containingPointingHand: PointingHandRegion? = nil
}

private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    let isHovering: Binding<Bool>?
    @State private var region = PointingHandRegion()
    @Environment(\.containingPointingHand) private var containingPointingHand

    func body(content: Content) -> some View {
        content
            .environment(\.containingPointingHand, region)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    region.parent = containingPointingHand
                    region.isInside = true
                    region.points = enabled
                    if region.hasPointingCursor { NSCursor.pointingHand.set() }
                    isHovering?.wrappedValue = enabled
                case .ended:
                    resetCursor()
                }
            }
            .onChange(of: enabled) { _, enabled in
                guard region.isInside else { return }
                region.points = enabled
                (region.hasPointingCursor ? NSCursor.pointingHand : NSCursor.arrow).set()
                isHovering?.wrappedValue = enabled
            }
            .onDisappear { resetCursor() }
    }

    private func resetCursor() {
        let wasInside = region.isInside
        region.isInside = false
        region.points = false
        if wasInside {
            (region.hasPointingCursor ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        isHovering?.wrappedValue = false
    }
}
