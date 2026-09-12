import Foundation
import SpottyDomain
import SpottyRuntimeContracts

package extension PlaybackSessionRuntime {
    func serviceCapabilities() -> Set<SessionCommandKind> {
        guard terminationGate.allowsCommands else { return [] }
        var capabilities: Set<SessionCommandKind> = [.account]
        if !isTearingDown, serviceCommandLedger.count < 4_096 {
            if canStartPlayback {
                capabilities.formUnion([.play, .options, .transfer, .queueAppend, .queueRefresh])
            }
            if canTogglePlayback { capabilities.insert(.transport) }
            if canSkipTrack { capabilities.insert(.navigation) }
            if canStartPlayback, hasCurrentTrack { capabilities.insert(.seek) }
            if queueMutation != nil, queueReplacementToken == nil { capabilities.insert(.queueRemove) }
        }
        return capabilities
    }

    func serviceSnapshot() -> SessionSnapshot {
        boundedServiceSnapshot(
            SessionSnapshot(
                sessionID: sessionID, revision: presentationRevision, accountEpoch: accountEpoch,
                routeRevision: routeRevision, phase: state.session, owner: state.owner,
                presentation: PlaybackPresentationSnapshot(
                    currentTrack: state.currentTrack, transport: state.transport, timing: state.timing),
                options: state.options, queue: state.queue, devices: state.devices,
                capabilities: serviceCapabilities(), receipts: serviceReceipts,
                needsReauthentication: requiresReauthentication, isRetiring: isTearingDown))
    }
}

/// Preserve complete identifiers or omit the corresponding row. Truncated queue evidence cannot
/// authorize replacement. The byte budget leaves room for the versioned transport envelope.
package func boundedServiceSnapshot(_ snapshot: SessionSnapshot) -> SessionSnapshot {
    var result = snapshot
    func identity(_ value: String) -> Bool { value.utf8.count <= 4_096 }
    func label(_ value: String) -> String { String(value.prefix(512)) }
    func device(_ value: PlaybackDevice) -> PlaybackDevice {
        PlaybackDevice(id: value.id, name: label(value.name), type: label(value.type), isActive: value.isActive)
    }
    func owner(_ value: PlaybackOwner) -> PlaybackOwner {
        switch value {
        case let .local(value): return identity(value.id) ? .local(device(value)) : .uncertain(nil)
        case let .remote(value): return identity(value.id) ? .remote(device(value)) : .uncertain(nil)
        case let .uncertain(value): return .uncertain(value.flatMap { identity($0.id) ? device($0) : nil })
        case .none: return .none
        }
    }
    result.owner = owner(result.owner)
    if case let .failed(message) = result.phase { result.phase = .failed(label(message)) }
    if var track = result.presentation.currentTrack {
        if !identity(track.uri) {
            result.presentation.currentTrack = nil
        } else {
            track.title = track.title.map(label)
            track.artist = track.artist.map(label)
            if track.artworkURL.map({ !identity($0.absoluteString) }) == true { track.artworkURL = nil }
            if !track.duration.isFinite { track.duration = 0 }
            result.presentation.currentTrack = track
        }
    }
    if !result.presentation.timing.position.isFinite { result.presentation.timing.position = 0 }
    if !result.presentation.timing.duration.isFinite { result.presentation.timing.duration = 0 }
    if !result.presentation.timing.anchoredAt.timeIntervalSince1970.isFinite {
        result.presentation.timing.anchoredAt = .distantPast
    }
    if !result.queue.receivedAt.timeIntervalSince1970.isFinite { result.queue.receivedAt = .distantPast }
    if result.queue.contextURI.map({ !identity($0) }) == true { result.queue.contextURI = nil }
    var queueStringBytes = 0
    result.queue.entries = []
    for entry in snapshot.queue.entries.prefix(4_096) {
        guard identity(entry.id), identity(entry.uri), identity(entry.uid), identity(entry.provider) else { continue }
        let bytes = entry.id.utf8.count + entry.uri.utf8.count + entry.uid.utf8.count + entry.provider.utf8.count
        guard queueStringBytes + bytes <= 600_000 else { break }
        queueStringBytes += bytes
        result.queue.entries.append(entry)
    }
    result.devices.devices = Array(result.devices.devices.lazy.filter { identity($0.id) }.prefix(256)).map(device)
    if result.devices.localDeviceID.map({ !identity($0) }) == true { result.devices.localDeviceID = nil }
    if result.devices.lastRemoteDeviceID.map({ !identity($0) }) == true { result.devices.lastRemoteDeviceID = nil }
    result.receipts = result.receipts.suffix(128).map {
        SessionCommandReceipt(
            commandID: $0.commandID, sessionID: $0.sessionID,
            disposition: $0.disposition, message: $0.message.map(label))
    }
    let encoder = JSONEncoder()
    while ((try? encoder.encode(result).count) ?? Int.max) > 1_900_000 {
        if !result.queue.entries.isEmpty {
            result.queue.entries.removeLast(max(1, result.queue.entries.count / 4))
        } else if !result.devices.devices.isEmpty {
            result.devices.devices.removeLast(max(1, result.devices.devices.count / 4))
        } else {
            // All remaining fields have fixed cardinality and bounded scalar lengths above.
            break
        }
    }
    if result.queue.entries.count != snapshot.queue.entries.count
        || result.queue.contextURI != snapshot.queue.contextURI
    {
        result.queue.completeness = .partial
        result.capabilities.remove(.queueRemove)
    }
    if result.owner != snapshot.owner {
        // Labels may be shortened without changing a route; a removed oversized identity may not.
        if stableServiceOwnerID(result.owner) != stableServiceOwnerID(snapshot.owner) {
            result.capabilities.subtract([.play, .transport, .navigation, .seek, .options, .queueAppend, .queueRemove])
        }
    }
    return result
}

private func stableServiceOwnerID(_ owner: PlaybackOwner) -> String? {
    switch owner {
    case let .local(device), let .remote(device), let .uncertain(.some(device)): device.id
    case .none, .uncertain(nil): nil
    }
}
