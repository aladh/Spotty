import SwiftUI

/// The shuffle toggle shown in a `DetailActionRow` (playlists only).
struct DetailActionRowShuffle {
    let isEnabled: Bool
    let toggle: () -> Void

    init(isEnabled: Bool, toggle: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.toggle = toggle
    }
}

/// The single primary-action row beneath every detail header (album, artist, playlist): a large
/// green play button, an optional shuffle toggle, and optional trailing content (the playlist
/// search field).
struct DetailActionRow<Trailing: View>: View {
    let canPlay: Bool
    let playAccessibilityLabel: String
    let playAccessibilityHint: String?
    let shuffle: DetailActionRowShuffle?
    let play: () -> Void
    let trailing: () -> Trailing

    init(
        canPlay: Bool,
        playAccessibilityLabel: String,
        playAccessibilityHint: String? = nil,
        shuffle: DetailActionRowShuffle? = nil,
        play: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.canPlay = canPlay
        self.playAccessibilityLabel = playAccessibilityLabel
        self.playAccessibilityHint = playAccessibilityHint
        self.shuffle = shuffle
        self.play = play
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 24) {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black)
                    .offset(x: 2)
                    .frame(width: 56, height: 56)
                    .background(SpottyPalette.mediaGreen, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .pointingHandCursor(enabled: canPlay)
            .accessibilityLabel(playAccessibilityLabel)
            .modifier(OptionalAccessibilityHint(hint: playAccessibilityHint))
            .help(playAccessibilityLabel)

            if let shuffle {
                Button(action: shuffle.toggle) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 24))
                        .foregroundStyle(shuffle.isEnabled ? SpottyPalette.mediaGreen : .secondary)
                        .frame(width: 32, height: 40)
                        .overlay(alignment: .bottom) {
                            if shuffle.isEnabled {
                                Circle().fill(SpottyPalette.mediaGreen).frame(width: 4, height: 4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .pointingHandCursor(enabled: canPlay)
                .accessibilityLabel(shuffle.isEnabled ? "Disable shuffle" : "Enable shuffle")
                .help("Fewer repeats shuffle")
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, CatalogLayout.contentPadding)
        .frame(height: 96)
    }
}

extension DetailActionRow where Trailing == EmptyView {
    init(
        canPlay: Bool,
        playAccessibilityLabel: String,
        playAccessibilityHint: String? = nil,
        shuffle: DetailActionRowShuffle? = nil,
        play: @escaping () -> Void
    ) {
        self.init(
            canPlay: canPlay,
            playAccessibilityLabel: playAccessibilityLabel,
            playAccessibilityHint: playAccessibilityHint,
            shuffle: shuffle,
            play: play,
            trailing: { EmptyView() }
        )
    }
}

private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}
