import SpottyDomain

/// Native menus and hosted rows can outlive the account snapshot that created them.
/// Retain that rendered account through tracking, then let the playback facade revalidate
/// the current runtime lifetime and destination when admitting the command.
@MainActor
struct SidePanelPlaybackActions {
    private let player: PlaybackStore
    private let accountEpoch: UInt64

    init(player: PlaybackStore) {
        self.player = player
        accountEpoch = player.accountEpoch
    }

    private var isCurrentAccount: Bool { player.accountEpoch == accountEpoch }
    var canStartPlayback: Bool { isCurrentAccount && player.canStartPlayback }
    var canTogglePlayback: Bool { isCurrentAccount && player.canTogglePlayback }

    func play(uri: String) {
        guard isCurrentAccount else { return }
        player.play(uri: uri)
    }

    func togglePlayback() {
        guard isCurrentAccount else { return }
        player.togglePlayback()
    }

    func transfer(to device: ConnectDevice) {
        guard isCurrentAccount else { return }
        player.transferPlayback(to: device)
    }

    func canRemoveUpcomingQueue(selectedIDs: Set<QueueEntry.ID>) -> Bool {
        isCurrentAccount && player.canRemoveUpcomingQueue(selectedIDs: selectedIDs)
    }

    @discardableResult
    func removeUpcomingQueue(selectedIDs: Set<QueueEntry.ID>) -> Bool {
        guard isCurrentAccount else { return false }
        let count = QueueMutationSelection.orderedUpcoming(
            selectedIDs: selectedIDs, in: player.queueNextEntries
        ).count
        guard
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true, selectedUpcomingCount: count,
                isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: selectedIDs)
            ) == .removeUpcomingOccurrences
        else { return false }
        player.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
        return true
    }
}
