import SwiftUI

/// A low-contrast boundary between an artwork-led header and its native table.
struct CatalogTableDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.5))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
