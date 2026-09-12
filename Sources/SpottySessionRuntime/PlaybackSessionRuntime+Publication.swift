import Foundation
import SpottyDomain
import SpottyRuntimeContracts

package extension PlaybackSessionRuntime {
    func presentation() -> RuntimePresentation {
        flushPublication()
        return RuntimePresentation(
            revision: presentationRevision, semantic: semantic, timeline: timeline,
            queueEntries: presentedQueueEntries, devices: presentedDevices,
            localDeviceID: presentedLocalDeviceID, defaultLocalDevice: defaultLocalPlaybackDevice,
            commandRoute: commandRoute, currentTrackIndicator: currentTrackIndicator,
            playingContextURI: playingContextURI, catalogPlaybackAvailability: catalogPlaybackAvailability,
            accountEpoch: accountEpoch,
            engineGeneration: engineGeneration, queueInspectorOrderingVersion: queueInspectorOrderingVersion,
            requiresReauthentication: requiresReauthentication, isTearingDown: isTearingDown,
            allowsCommands: terminationGate.allowsCommands, catalogAvailable: catalogSession.isAvailable,
            history: history.entries, metadata: catalog.metadata.playbackTracks, feedback: feedback.message)
    }

    func presentations() -> AsyncStream<RuntimePresentation> {
        let id = UUID()
        let pair = AsyncStream<RuntimePresentation>.makeStream(bufferingPolicy: .bufferingNewest(1))
        presentationSubscribers[id] = pair.continuation
        pair.continuation.yield(presentation())
        pair.continuation.onTermination = { [weak self] _ in
            Task { @SessionRuntimeActor in self?.presentationSubscribers[id] = nil }
        }
        return pair.stream
    }

    func publish() {
        if sessionAccountEpoch != accountEpoch {
            sessionAccountEpoch = accountEpoch
            sessionID = UUID()
            serviceReceipts = []
            serviceCommandLedger = [:]
            serviceIntentIDs = [:]
            serviceIntentOutcomes = [:]
            serviceCommandActions = [:]
            serviceCommandEpochs = [:]
        }
        if lastServiceRoute != commandRoute {
            lastServiceRoute = commandRoute
            routeRevision &+= 1
        }
        guard !publicationPending else { return }
        publicationPending = true
        // Publication runs after the current synchronous transition. In particular, account
        // invalidation and reducer reset cannot expose an intermediate mixed-account snapshot.
        Task { @SessionRuntimeActor [weak self] in self?.flushPublication() }
    }

    func flushPublication() {
        guard publicationPending else { return }
        publicationPending = false
        presentationRevision &+= 1
        synchronizeServiceReceipts()
        rolloverServiceSessionIfNeeded()
        if !presentationSubscribers.isEmpty {
            let value = presentation()
            for subscriber in presentationSubscribers.values { subscriber.yield(value) }
        }
        if !serviceSubscribers.isEmpty {
            let value = serviceSnapshot()
            for subscriber in serviceSubscribers.values { subscriber.yield(value) }
        }
    }

    /// A client can contribute labels only for the same account. This never supplies Connect
    /// ordering, device ownership, command readiness or playlist write authorization.
    @discardableResult
    func acceptCatalogMetadata(_ tracks: [CatalogTrack], accountEpoch: UInt64) -> Bool {
        guard self.accountEpoch == accountEpoch, catalogSession.isAvailable, !isTearingDown else { return false }
        catalog.metadata.replaceTracks(tracks, from: .browsing)
        return true
    }

}
