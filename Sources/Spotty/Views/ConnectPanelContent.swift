import SpottyDomain
import SwiftUI

struct ConnectPanelContent: View {
    let player: PlaybackStore

    private var currentDevice: ConnectDevice? {
        player.activeRemoteDevice ?? player.connectDevices.first(where: \.isActive)
    }

    private var availableDevices: [ConnectDevice] {
        let devices = player.connectDevices.filter { $0.id != currentDevice?.id }
        return devices.filter { $0.id == player.localDeviceID }
            + devices.filter { $0.id != player.localDeviceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let device = currentDevice {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ConnectDeviceIcon(device: device)
                                Text(deviceName(device))
                                    .font(.system(size: 16))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(SpottyPalette.mediaGreen)
                            Text("\(player.isPlaying ? "Playing" : "Paused") on \(deviceName(device))")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(white: 0.7))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.122), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Current device, \(deviceName(device)), \(player.isPlaying ? "Playing" : "Paused")")
                    }

                    VStack(spacing: 0) {
                        ForEach(availableDevices) { device in
                            ConnectDeviceRow(device: device, name: deviceName(device)) {
                                player.transferPlayback(to: device)
                            }
                            .disabled(!player.canStartPlayback || player.isPlaybackCommandPending)
                        }
                    }

                    if player.connectDevices.isEmpty {
                        Text(player.isConnected ? "No devices found" : "Connect Spotify to see available devices.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(white: 0.7))
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 8)
            }

        }
    }

    private func deviceName(_ device: ConnectDevice) -> String {
        device.id == player.localDeviceID ? "This computer" : device.name
    }

}

private struct ConnectDeviceRow: View {
    let device: ConnectDevice
    let name: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ConnectDeviceIcon(device: device)
                Text(name)
                    .font(.system(size: 16))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(SpottyPalette.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Color(white: 0.165) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Connect to \(name)")
    }
}

private struct ConnectDeviceIcon: View {
    let device: ConnectDevice

    var body: some View {
        if device.type.lowercased() == "computer" {
            PlaybackUtilitySymbol(kind: .computer)
                .fill(style: FillStyle(eoFill: true))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else {
            Image(systemName: device.symbolName)
                .font(.system(size: 22))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }
}
