import SpottyDomain
import SpottyRuntimeContracts
import SwiftUI

struct ArtistDetailView: View {
    let item: CatalogItem
    let store: ArtistDetailStore
    let playback: CatalogPlaybackAccess
    let onSelect: (CatalogItem) -> Void
    let onShowDiscography: (ArtistReleaseFilter) -> Void
    @Bindable var interactionState: CatalogRouteInteractionState
    @State private var viewportHeight: CGFloat = 800

    private var displayedItem: CatalogItem {
        store.item?.uri == item.uri ? (store.item ?? item) : item
    }

    private var heroHeight: CGFloat { min(400, max(280, viewportHeight * 0.5)) }

    var body: some View {
        TrackTable(
            tracks: interactionState.artistShowsAllTracks ? store.popularTracks : store.popularPreview,
            playback: playback, variant: .artist, onSelect: onSelect,
            detailHeader: AnyView(expandedHeader), compactDetailHeader: AnyView(compactHeader),
            detailFooter: AnyView(footer), artistTracks: store.artistTracks,
            detailHeaderCollapseOffset: heroHeight - 64,
            interactionState: interactionState
        )
        .id(item.uri)
        .navigationTitle(displayedItem.title)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            viewportHeight = $0
        }
        .catalogTask(id: item.uri, playback: playback) {
            await store.load(item)
        }
    }

    private var expandedHeader: some View {
        VStack(spacing: 0) {
            ArtistHeroHeader(
                item: displayedItem, overview: store.overview, height: heroHeight)
            DetailHeroBackground(
                artworkURL: store.overview?.headerArtworkURL ?? displayedItem.artworkURL, tintOpacity: 0.5
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    DetailActionRow(
                        action: playback.action(for: displayedItem, behavior: .activateSelection),
                        shuffle: DetailActionRowShuffle(
                            isEnabled: playback.isShuffleEnabled, canToggle: playback.canStartPlayback
                        ) {
                            playback.toggleShuffle()
                        }
                    )
                    if store.isShowingCachedContent {
                        CachedCatalogNotice(
                            isRefreshing: store.isLoading, error: hasContent ? store.error : nil,
                            canRetry: playback.isConnected
                        ) {
                            guard playback.isConnected else { return }
                            await store.load(item, force: true)
                        }
                    }
                    if !store.popularTracks.tracks.isEmpty {
                        Text("Popular")
                            .font(.system(size: 24, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, CatalogLayout.contentPadding)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private var compactHeader: some View {
        CompactMediaDetailHeader(
            title: displayedItem.title, action: playback.action(for: displayedItem, behavior: .activateSelection)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 28) {
            if store.popularTracks.tracks.count > 5 {
                Button(interactionState.artistShowsAllTracks ? "See less" : "See more") {
                    interactionState.artistShowsAllTracks.toggle()
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(SpottyPalette.textSecondary)
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel(
                    interactionState.artistShowsAllTracks ? "Show fewer popular tracks" : "Show more popular tracks"
                )
                .padding(.horizontal, 16)
            }
            CatalogContentState(
                isLoading: store.isLoading,
                isEmpty: !hasContent,
                error: store.error, loadingLabel: "Loading artist", errorTitle: "Couldn't load artist",
                connection: playback,
                retry: { await store.load(item) }
            ) {
                EmptyState(
                    icon: "person.wave.2", title: "No music", message: "Spotify returned no music for this artist.")
            } content: {
                if hasReleases { discography }
                if !featuringPlaylists.isEmpty {
                    MediaShelf(
                        section: CatalogSection(
                            id: "featuring", title: "Featuring \(displayedItem.title)", items: featuringPlaylists),
                        playback: playback, titleLineLimit: 2, onSelect: onSelect)
                }
                if hasAbout, let overview = store.overview {
                    ArtistAboutSection(item: displayedItem, overview: overview)
                }
                if !discoveredOnPlaylists.isEmpty {
                    MediaShelf(
                        section: CatalogSection(
                            id: "discovered-on", title: "Discovered on", items: discoveredOnPlaylists),
                        playback: playback, titleLineLimit: 2, onSelect: onSelect)
                }
                if !artistPlaylists.isEmpty {
                    MediaShelf(
                        section: CatalogSection(
                            id: "artist-playlists", title: "Artist Playlists", items: artistPlaylists),
                        playback: playback, titleLineLimit: 2, onSelect: onSelect)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CatalogLayout.contentPadding)
        .padding(.top, 16)
        .padding(.bottom, 40)
    }

    private var featuringPlaylists: [CatalogItem] { store.overview?.featuringPlaylists ?? [] }
    private var discoveredOnPlaylists: [CatalogItem] { store.overview?.discoveredOnPlaylists ?? [] }
    private var artistPlaylists: [CatalogItem] { store.overview?.artistPlaylists ?? [] }
    private var hasContent: Bool {
        hasReleases || !store.popularTracks.tracks.isEmpty || !featuringPlaylists.isEmpty
            || hasAbout || !discoveredOnPlaylists.isEmpty || !artistPlaylists.isEmpty
    }

    private var hasAbout: Bool {
        guard let overview = store.overview else { return false }
        return overview.biography?.isEmpty == false || overview.aboutArtworkURL != nil
            || overview.monthlyListeners != nil
    }

    private var hasReleases: Bool {
        !store.releases.isEmpty || store.overview?.popularReleases.isEmpty == false
    }

    private var availableFilters: [ArtistReleaseFilter] {
        ArtistReleaseFilter.allCases.filter { filter in
            filter == .popular || !releases(for: filter).isEmpty
        }
    }

    private var selectedFilter: ArtistReleaseFilter {
        availableFilters.contains(interactionState.artistReleaseFilter)
            ? interactionState.artistReleaseFilter : .popular
    }

    private func releases(for filter: ArtistReleaseFilter) -> [CatalogItem] {
        if filter == .popular {
            let popular = store.overview?.popularReleases ?? []
            return popular.isEmpty ? store.releases : popular
        }
        return store.releases.filter { release in
            switch (filter, store.releaseKinds[release.uri]) {
            case (.albums, .album), (.singles, .single), (.singles, .ep), (.compilations, .compilation): true
            default: false
            }
        }
    }

    private var discography: some View {
        let releases = releases(for: selectedFilter)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Discography").font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if hasReleases {
                    Button("Show all") { onShowDiscography(selectedFilter) }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SpottyPalette.textSecondary)
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("Show all releases")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filterButtons }
                NativeHorizontalScroll {
                    HStack(spacing: 8) { filterButtons }
                }
            }
            MediaCardRow(items: Array(releases.prefix(6)), playback: playback, onSelect: onSelect)
        }
    }

    private var filterButtons: some View {
        ForEach(availableFilters, id: \.self) { filter in
            let selected = selectedFilter == filter
            let title =
                filter == .popular
                    && store.overview?.popularReleases.isEmpty != false
                ? "All releases" : filter.rawValue
            Button(title) {
                interactionState.artistReleaseFilter = filter
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(selected ? Color.black : SpottyPalette.textPrimary)
            .background(selected ? Color.white : SpottyPalette.selectedControl, in: Capsule())
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

private struct ArtistHeroHeader: View {
    let item: CatalogItem
    let overview: CatalogArtistOverview?
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let banner = overview?.headerArtworkURL {
                    RemoteArtwork(url: banner, kind: .artist, cornerRadius: 0, showsBorder: false)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                } else {
                    DetailHeroBackground(artworkURL: item.artworkURL) { Color.clear }
                }
                HStack(alignment: .bottom, spacing: 24) {
                    if overview?.headerArtworkURL == nil, item.artworkURL != nil {
                        RemoteArtwork(url: item.artworkURL, kind: .artist, cornerRadius: 100)
                            .frame(
                                width: geometry.size.width >= 560 ? 200 : 112,
                                height: geometry.size.width >= 560 ? 200 : 112)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title)
                            .font(.system(size: min(96, max(48, geometry.size.width * 0.125)), weight: .black))
                            .tracking(-2)
                            .lineLimit(2)
                            .minimumScaleFactor(0.65)
                            .accessibilityAddTraits(.isHeader)
                        if overview?.isVerified == true {
                            Label {
                                Text("Verified by Spotify").font(.system(size: 12, weight: .semibold))
                            } icon: {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 22)).foregroundStyle(Color(red: 0.7, green: 0.96, blue: 0.78))
                            }
                        }
                        if let listeners = overview?.monthlyListeners {
                            Text("\(listeners.formatted()) monthly listeners").font(.system(size: 16))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, CatalogLayout.contentPadding)
                .padding(.bottom, 28)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(height: height)
        .foregroundStyle(SpottyPalette.textPrimary)
    }
}
