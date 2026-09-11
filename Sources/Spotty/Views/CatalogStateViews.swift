import SwiftUI

struct LoadingState: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .foregroundStyle(SpottyPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionSystemImage {
                        Label(actionTitle, systemImage: actionSystemImage)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// Shared initial-load ladder. Existing content survives refreshes and refresh failures.
/// Callers retain their containers, empty-state copy, and any surface-specific disconnected UI.
struct CatalogContentState<Empty: View, Content: View>: View {
    let isLoading: Bool
    let isEmpty: Bool
    let error: String?
    let loadingLabel: String
    let errorTitle: String
    var errorIcon = "exclamationmark.triangle"
    var placeholderPadding: CGFloat = 0
    var connection: CatalogPlaybackAccess? = nil
    var connectionIcon = "person.crop.circle.badge.plus"
    var connectionTitle = "Connect Spotify"
    var connectionMessage: String? = nil
    var disconnectOverridesContent = false
    let retry: () async -> Void
    @ViewBuilder let empty: () -> Empty
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isLoading && isEmpty {
            LoadingState(label: loadingLabel).padding(placeholderPadding)
        } else if let connection, !connection.isConnected, isEmpty || disconnectOverridesContent {
            EmptyState(
                icon: connectionIcon, title: connectionTitle,
                message: connectionMessage ?? connection.statusText,
                actionTitle: connection.connectionActionTitle, actionSystemImage: "link"
            ) { connection.connect() }
            .padding(placeholderPadding)
        } else if isEmpty {
            if let error {
                CatalogFailureState(title: errorTitle, message: error, icon: errorIcon, retry: retry)
                    .padding(placeholderPadding)
            } else {
                empty().padding(placeholderPadding)
            }
        } else {
            content()
        }
    }
}

struct CatalogFailureState: View {
    let title: String
    let message: String
    var icon = "exclamationmark.triangle"
    let retry: () async -> Void

    var body: some View {
        EmptyState(
            icon: icon, title: title, message: message,
            actionTitle: "Try Again", actionSystemImage: "arrow.clockwise"
        ) { Task { await retry() } }
    }
}
