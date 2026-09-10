import SwiftUI

struct NowPlayingTrackIdentity: View {
    let player: PlaybackStore

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if player.hasCurrentTrack {
                    RemoteArtwork(url: player.displayedArtworkURL, kind: .track, cornerRadius: 3)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
                        Image(systemName: "music.note")
                            .font(.body.weight(.medium))
                            .foregroundStyle(SpottyPalette.playerSecondary)
                    }
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(SpottyPalette.playerDivider) }
                    .accessibilityHidden(true)
                }
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.displayedTrackTitle)
                    .font(.system(size: 14))
                    .foregroundStyle(SpottyPalette.playerPrimary)
                    .lineLimit(1)
                Text(player.displayedArtistName)
                    .font(.system(size: 12))
                    .foregroundStyle(SpottyPalette.playerSecondary)
                    .lineLimit(1)
            }
            .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            player.hasCurrentTrack
                ? "Now playing \(player.displayedTrackTitle) by \(player.displayedArtistName)"
                : "No track playing"
        )
    }
}

struct NowPlayingProgress: View {
    let player: PlaybackStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let accountEpoch = player.semantic.accountEpoch
        let engineEpoch = player.semantic.engineEpoch
        let owner = player.semantic.owner
        let trackURI = player.trackURI
        let duration = player.hasCurrentTrack ? player.duration : 0
        PlaybackPositionSlider(
            position: player.position, anchoredAt: player.positionAnchorDate, duration: duration,
            isEnabled: player.canStartPlayback && player.hasCurrentTrack && duration > 0,
            isPlaying: player.showsPauseControl, reduceMotion: reduceMotion
        ) { position in
            // A drag belongs to the track, owner, and lifetime where it began.
            guard player.canStartPlayback, player.hasCurrentTrack,
                player.semantic.accountEpoch == accountEpoch, player.semantic.engineEpoch == engineEpoch,
                player.semantic.owner == owner, player.trackURI == trackURI,
                player.duration == duration, duration > 0
            else { return }
            player.seek(to: position / duration)
        }
        .frame(height: 20)
    }
}

struct NowPlayingTransportControls: View {
    let player: PlaybackStore

    var body: some View {
        HStack(spacing: 8) {
            optionButton(
                symbol: .shuffle,
                active: player.isShuffleEnabled,
                label: player.isShuffleEnabled ? "Shuffle on, fewer repeats" : "Shuffle off",
                help: player.isShuffleEnabled ? "Fewer repeats shuffle is on" : "Turn on fewer repeats shuffle",
                action: player.toggleShuffle
            )
            TransportIconButton(
                symbol: .previous, label: "Previous", disabled: !player.canSkipTrack, action: player.previous)
            Button(action: player.togglePlayback) {
                ZStack {
                    Circle().fill(
                        player.canTogglePlayback
                            ? SpottyPalette.playerPrimary
                            : SpottyPalette.playerDisabledControl
                    )
                    TransportSymbol(kind: player.showsPauseControl ? .pause : .play)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(
                            player.canTogglePlayback
                                ? SpottyPalette.playerButtonForeground
                                : SpottyPalette.playerDisabledForeground
                        )

                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .disabled(!player.canTogglePlayback)
            .pointingHandCursor(enabled: player.canTogglePlayback)
            .help(player.hasCurrentTrack ? (player.showsPauseControl ? "Pause" : "Play") : "Choose music to begin")
            .accessibilityLabel(player.showsPauseControl ? "Pause" : "Play")
            TransportIconButton(
                symbol: .next, label: "Next", disabled: !player.canSkipTrack, action: player.next)
            optionButton(
                symbol: player.repeatMode == .track ? .repeatOne : .repeatAll,
                active: player.repeatMode != .off,
                label: player.repeatMode.accessibilityLabel,
                help: player.repeatMode.accessibilityLabel,
                action: player.cycleRepeat
            )
        }
    }

    private func optionButton(
        symbol: TransportSymbol.Kind,
        active: Bool,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TransportSymbol(kind: symbol)
                .frame(width: 16, height: 16)
                .foregroundStyle(
                    active ? SpottyPalette.mediaGreen : SpottyPalette.playerSecondary
                )
                .frame(width: 32, height: 32)
                .overlay(alignment: .bottom) {
                    if active {
                        Circle().fill(SpottyPalette.mediaGreen).frame(width: 4, height: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!player.canStartPlayback)
        .pointingHandCursor(enabled: player.canStartPlayback)
        .help(help)
        .accessibilityLabel(label)
    }
}

enum PlaybackPanel: String {
    case queue, connect
}

struct NowPlayingTimeControls: View {
    let player: PlaybackStore
    @Binding var showsSidePanel: Bool
    @Binding var playbackPanel: PlaybackPanel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var queueIsOpen: Bool { showsSidePanel && playbackPanel == .queue }
    private var connectIsOpen: Bool { showsSidePanel && playbackPanel == .connect }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                toggle(.queue)
            } label: {
                PlayerUtilityIcon(kind: .queue, isOpen: queueIsOpen)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(queueIsOpen ? "Hide queue and history" : "Show queue and history")
            .accessibilityLabel(queueIsOpen ? "Hide queue and history panel" : "Show queue and history panel")
            .accessibilityValue(queueIsOpen ? "Open" : "Closed")

            Button {
                toggle(.connect)
            } label: {
                PlayerUtilityIcon(
                    kind: player.activeRemoteDevice?.type.lowercased() == "computer" ? .computer : .devices,
                    isOpen: connectIsOpen
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Connect to a device")
            .accessibilityLabel("Playback devices")
            .accessibilityValue(connectIsOpen ? "Open" : "Closed")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback devices and queue controls")
    }

    private func toggle(_ panel: PlaybackPanel) {
        let update = {
            if showsSidePanel && playbackPanel == panel {
                showsSidePanel = false
            } else {
                playbackPanel = panel
                showsSidePanel = true
            }
        }
        if reduceMotion { update() } else { withAnimation(.snappy(duration: 0.2), update) }
    }
}

private struct TransportIconButton: View {
    let symbol: TransportSymbol.Kind
    let label: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            TransportSymbol(kind: symbol)
                .frame(width: 16, height: 16)
                .foregroundStyle(SpottyPalette.playerSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .pointingHandCursor(enabled: !disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
