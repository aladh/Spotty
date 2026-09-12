import SwiftUI

struct CachedCatalogNotice: View {
    let isRefreshing: Bool

    var body: some View {
        Text(isRefreshing ? "Showing saved content while refreshing…" : "Showing saved content. It may be out of date.")
            .font(.subheadline)
            .foregroundStyle(SpottyPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CatalogLayout.contentPadding)
            .padding(.vertical, 10)
    }
}
