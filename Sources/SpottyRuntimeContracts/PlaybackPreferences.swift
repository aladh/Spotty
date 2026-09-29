import Foundation

package nonisolated protocol PlaybackPreferences: Sendable {
    func shuffleEnabled() async -> Bool
    func setShuffleEnabled(_ enabled: Bool) async
    func lastRemoteDeviceID() async -> String?
    func setLastRemoteDeviceID(_ id: String?) async
    func shuffleHistory() async -> [String: TimeInterval]
    func setShuffleHistory(_ history: [String: TimeInterval]) async
}
