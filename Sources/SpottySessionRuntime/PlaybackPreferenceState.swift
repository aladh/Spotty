import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Saved scalars are startup seeds; observed plays are changes to a saved dictionary. This owner
/// keeps their different restoration rules beside write admission so a partial cache cannot be saved.
@SessionRuntimeActor
final class PlaybackPreferenceState {
    private let storage: any PlaybackPreferences
    private let writer: PlaybackPreferenceWriter
    private var epoch: UInt64
    private var acceptsChanges = true
    private var acceptsRestoration = true
    private var didStartRestoration = false
    private var shuffleSeedSuperseded = false
    private var remoteSeedSuperseded = false
    private var historyLoaded = false
    private var historyRead: Task<Void, Never>?
    private var pendingPlays: [String: TimeInterval] = [:]
    private var latestPlayTime: TimeInterval?

    private(set) var lastRemoteDeviceID: String?
    private(set) var shuffleHistory: [String: TimeInterval] = [:]

    init(storage: any PlaybackPreferences, accountEpoch: UInt64) {
        self.storage = storage
        writer = PlaybackPreferenceWriter(preferences: storage)
        epoch = accountEpoch
    }

    func restore(applyShuffle: (Bool) -> Void) async {
        guard !Task.isCancelled, acceptsRestoration, !didStartRestoration else { return }
        didStartRestoration = true
        let restoringEpoch = epoch
        let shuffle = await storage.shuffleEnabled()
        guard !Task.isCancelled, acceptsRestoration, epoch == restoringEpoch else { return }
        if !shuffleSeedSuperseded { applyShuffle(shuffle) }
        let remoteID = await storage.lastRemoteDeviceID()
        guard !Task.isCancelled, acceptsRestoration, epoch == restoringEpoch else { return }
        if !remoteSeedSuperseded { lastRemoteDeviceID = remoteID }
        startHistoryReadIfNeeded()
        await historyRead?.value
    }

    /// Occurrence matters even when an accepted observation equals the current Boolean.
    func supersedeShuffleSeed() { shuffleSeedSuperseded = true }

    func cancelRestoration() {
        acceptsRestoration = false
        // A play's read-modify-write is persistence work, independent of the startup seed effect.
        if pendingPlays.isEmpty { historyRead?.cancel() }
    }

    func persistShuffle(_ enabled: Bool, accountEpoch: UInt64) {
        guard acceptsChanges, epoch == accountEpoch else { return }
        writer.submit(epoch: epoch, .shuffle(enabled))
    }

    func rememberRemoteDevice(_ id: String, accountEpoch: UInt64) {
        guard acceptsChanges, epoch == accountEpoch else { return }
        remoteSeedSuperseded = true
        guard lastRemoteDeviceID != id else { return }
        lastRemoteDeviceID = id
        writer.submit(epoch: epoch, .remoteDevice(id))
    }

    func recordPlayed(_ uri: String, at time: TimeInterval, accountEpoch: UInt64) {
        guard acceptsChanges, epoch == accountEpoch, !uri.isEmpty else { return }
        shuffleHistory[uri] = time
        shuffleHistory = ShufflePolicy.pruned(shuffleHistory, now: time)
        if historyLoaded {
            writer.submit(epoch: epoch, .history(shuffleHistory))
        } else {
            // Keep the last occurrence per URI, including across a backward clock adjustment.
            pendingPlays[uri] = time
            latestPlayTime = time
            startHistoryReadIfNeeded()
        }
    }

    /// Retirement never waits for a read. A late old-account baseline cannot restore or enqueue
    /// writes, while the existing writer still orders any entered write before the later clear.
    func retireAccount(to accountEpoch: UInt64) {
        epoch = accountEpoch
        acceptsRestoration = false
        shuffleSeedSuperseded = true
        remoteSeedSuperseded = true
        historyRead?.cancel()
        historyRead = nil
        historyLoaded = true
        pendingPlays.removeAll()
        latestPlayTime = nil
        shuffleHistory.removeAll()
    }

    func clearHistory() { writer.submit(epoch: epoch, .history([:])) }

    func forgetRemoteDevice() {
        remoteSeedSuperseded = true
        lastRemoteDeviceID = nil
        writer.submit(epoch: epoch, .remoteDevice(nil))
    }

    /// Quit stops seeds and new mutations, but accepted plays still need their saved baseline.
    /// The application's existing termination deadline bounds an unresponsive storage adapter.
    func prepareForTermination() {
        acceptsChanges = false
        cancelRestoration()
    }

    func flush() async {
        if !pendingPlays.isEmpty { await historyRead?.value }
        await writer.flush()
    }

    private func startHistoryReadIfNeeded() {
        guard !historyLoaded, historyRead == nil else { return }
        let readingEpoch = epoch
        historyRead = Task { [weak self, storage] in
            let saved = await storage.shuffleHistory()
            self?.finishHistoryRead(saved, accountEpoch: readingEpoch)
        }
    }

    private func finishHistoryRead(_ saved: [String: TimeInterval], accountEpoch: UInt64) {
        guard epoch == accountEpoch else { return }
        guard acceptsRestoration || !pendingPlays.isEmpty else {
            // A cancelled seed never hydrated the visible cache. A later play must read the
            // baseline again before saving; treating that empty cache as loaded would erase it.
            historyRead = nil
            return
        }
        var merged = saved
        if let latestPlayTime {
            merged.merge(pendingPlays) { _, observed in observed }
            merged = ShufflePolicy.pruned(merged, now: latestPlayTime)
            writer.submit(epoch: epoch, .history(merged))
        }
        if acceptsChanges { shuffleHistory = merged }
        pendingPlays.removeAll()
        latestPlayTime = nil
        historyLoaded = true
        historyRead = nil
    }
}
