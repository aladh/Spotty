import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI

struct ArtistAboutSection: View {
    let item: CatalogItem
    let overview: CatalogArtistOverview
    @State private var showsBiography = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.system(size: 24, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Button {
                showsBiography = true
            } label: {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        SpottyPalette.selectedControl
                        if let url = overview.aboutArtworkURL {
                            RemoteArtwork(url: url, kind: .artist, cornerRadius: 0, showsBorder: false)
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            if let listeners = overview.monthlyListeners {
                                Text("\(listeners.formatted()) monthly listeners").fontWeight(.bold)
                            }
                            if let biography = overview.biography, !biography.isEmpty {
                                Text(biography).lineLimit(3)
                            }
                        }
                        .font(.system(size: 16))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(geometry.size.width < 480 ? 24 : 40)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .scaleEffect(isHovering ? 1.01 : 1)
                }
                .frame(height: 400)
                .frame(maxWidth: 840)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SpottyPalette.textPrimary)
            .pointingHandCursor(isHovering: $isHovering)
            .accessibilityLabel("About \(item.title)")
            .accessibilityHint("Opens the full artist biography and audience details")
        }
        .sheet(isPresented: $showsBiography) {
            ArtistBiographySheet(item: item, overview: overview)
        }
    }
}

private struct ArtistBiographySheet: View {
    let item: CatalogItem
    let overview: CatalogArtistOverview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let url = overview.aboutArtworkURL {
                    RemoteArtwork(url: url, kind: .artist, cornerRadius: 0, showsBorder: false, contentMode: .fit)
                        .frame(height: 300)
                        .background(.black)
                }
                VStack(alignment: .leading, spacing: 24) {
                    Text("About \(item.title)")
                        .font(.system(size: 24, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    HStack(alignment: .top, spacing: 40) {
                        if let followers = overview.followers { statistic(followers, label: "Followers") }
                        if let listeners = overview.monthlyListeners {
                            statistic(listeners, label: "Monthly listeners")
                        }
                    }
                    if let biography = overview.biography, !biography.isEmpty {
                        Text(biography)
                            .font(.system(size: 16))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(32)
            }
        }
        .background(SpottyPalette.catalogCanvas)
        .foregroundStyle(SpottyPalette.textPrimary)
        .overlay(alignment: .topTrailing) {
            Button("Close artist biography", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .semibold))
                .padding(12)
                .background(.black.opacity(0.8), in: Circle())
                .buttonStyle(.plain)
                .pointingHandCursor()
                .keyboardShortcut(.cancelAction)
                .padding(16)
        }
        .frame(width: 680, height: 620)
    }

    private func statistic(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.system(size: 28, weight: .bold))
            Text(label).font(.system(size: 14)).foregroundStyle(SpottyPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
