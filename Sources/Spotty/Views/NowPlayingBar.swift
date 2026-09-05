import SpottyDomain
import SwiftUI

struct NowPlayingBar: View {
    let player: PlaybackStore
    @Binding var showsSidePanel: Bool
    @Binding var playbackPanel: PlaybackPanel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let notice = player.playbackNotice {
                PlaybackNoticeBanner(notice: notice) {
                    player.dismissPlaybackNotice(id: notice.id)
                }
            }

            GeometryReader { geometry in
                HStack(spacing: 18) {
                    NowPlayingTrackIdentity(player: player)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        NowPlayingTransportControls(player: player)

                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            HStack(spacing: 8) {
                                playerTimeLabel(
                                    player.hasCurrentTrack
                                        ? formatDuration(player.displayedPosition(at: timeline.date)) : "—:—",
                                    alignment: .trailing
                                )

                                NowPlayingProgress(player: player)

                                playerTimeLabel(remainingTime(at: timeline.date), alignment: .leading)
                            }
                            .font(.system(size: 12).monospacedDigit())
                        }
                    }
                    .frame(width: min(722, geometry.size.width * 0.4))

                    NowPlayingTimeControls(
                        player: player, showsSidePanel: $showsSidePanel, playbackPanel: $playbackPanel
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
            }
            .frame(height: 80)
            .background(.black)

            if let banner = player.remotePlaybackBanner {
                RemotePlaybackBanner(device: banner.device, isPlaying: banner.isPlaying)
            }
        }
        .animationIfAllowed(
            .snappy(duration: 0.2),
            value: player.hasCurrentTrack,
            reduceMotion: reduceMotion
        )
        .animationIfAllowed(
            .snappy(duration: 0.2),
            value: player.remotePlaybackBanner?.device.id,
            reduceMotion: reduceMotion
        )
        .task(id: player.showsPauseControl) {
            guard player.showsPauseControl else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                player.refreshPosition()
            }
        }
    }

    private func remainingTime(at date: Date) -> String {
        guard player.hasCurrentTrack, player.duration > 0 else { return "—:—" }
        return "−\(formatDuration(max(0, player.duration - player.displayedPosition(at: date))))"
    }

    private func playerTimeLabel(_ value: String, alignment: Alignment) -> some View {
        Text(value)
            .foregroundStyle(SpottyPalette.playerSecondary)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.7)
            .frame(width: 44, alignment: alignment)
    }
}

private struct RemotePlaybackBanner: View {
    let device: ConnectDevice
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            PlaybackUtilitySymbol(kind: device.type.lowercased() == "computer" ? .computer : .devices)
                .fill(style: FillStyle(eoFill: true))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text("\(isPlaying ? "Playing" : "Paused") on \(device.name)")
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(SpottyPalette.remotePlaybackForeground)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .background(SpottyPalette.mediaGreen, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isPlaying ? "Playing" : "Paused") on \(device.name)")
    }
}

private struct PlaybackNoticeBanner: View {
    let notice: PlaybackNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            Text(notice.message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss playback notice", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss playback notice")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .onChange(of: notice.id, initial: true) { _, _ in
            AccessibilityNotification.Announcement(notice.message).post()
        }
    }
}
