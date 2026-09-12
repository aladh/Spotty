/// Where the device id lives. Stable across launches on purpose: it identifies this
/// installation to Spotify, and a new one on every launch looks like a new device each time.
public nonisolated protocol DeviceIdStoring: Sendable {
    func deviceId() -> String
}
