import SwiftUI

struct CachedCatalogNotice: View {
    let isRefreshing: Bool
    var error: String? = nil
    var canRetry = false
    var retry: (() async -> Void)? = nil

    private var message: String {
        if isRefreshing { return "Showing saved content while refreshing…" }
        if let error { return "Showing saved content. \(error)" }
        return "Showing saved content. It may be out of date."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .foregroundStyle(SpottyPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let error, let retry {
                Button("Try Again") { Task { await retry() } }
                    .disabled(isRefreshing || !canRetry)
                    .help(error)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.vertical, 10)
    }
}
