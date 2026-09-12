import Foundation
@testable import SpottyCore
@testable import SpottySessionRuntime

/// Lock-protected continuation so cancellation and resume do not hop onto an
/// actor that is already waiting in that continuation.
private final class ParkedGate: @unchecked Sendable {
    private struct Storage {
        var pending = false
        var waiting = false
        var resumeRequested = false
        var continuation: CheckedContinuation<Void, Never>?
        var generation: UInt64 = 0
    }

    private let lock = NSLock()
    private var storage = Storage()

    private func withStorage<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    func parkNext() {
        let displaced = withStorage { storage -> CheckedContinuation<Void, Never>? in
            storage.pending = true
            storage.resumeRequested = false
            let parked = storage.continuation
            storage.continuation = nil
            return parked
        }
        displaced?.resume()
    }

    func isParked() -> Bool {
        withStorage { $0.continuation != nil }
    }

    func resume() {
        let parked = withStorage { storage -> CheckedContinuation<Void, Never>? in
            if let parked = storage.continuation {
                storage.continuation = nil
                return parked
            }
            if storage.waiting {
                storage.resumeRequested = true
            }
            return nil
        }
        parked?.resume()
    }

    func waitIfPending() async {
        let id = withStorage { storage -> UInt64 in
            guard storage.pending else { return 0 }
            storage.pending = false
            storage.waiting = true
            storage.resumeRequested = false
            storage.generation &+= 1
            return storage.generation
        }
        guard id != 0 else { return }
        defer {
            withStorage { storage in
                if storage.generation == id {
                    storage.waiting = false
                }
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enum Install {
                    case resumeNow
                    case displaced(CheckedContinuation<Void, Never>)
                    case stored
                }
                let install = withStorage { storage -> Install in
                    if Task.isCancelled || storage.generation != id || storage.resumeRequested {
                        storage.resumeRequested = false
                        return .resumeNow
                    }
                    let displaced = storage.continuation
                    storage.continuation = continuation
                    if let displaced {
                        return .displaced(displaced)
                    }
                    return .stored
                }
                switch install {
                case .resumeNow:
                    continuation.resume()
                case let .displaced(previous):
                    previous.resume()
                case .stored:
                    break
                }
            }
        } onCancel: {
            let parked = withStorage { storage -> CheckedContinuation<Void, Never>? in
                guard storage.generation == id else { return nil }
                let parked = storage.continuation
                storage.continuation = nil
                storage.resumeRequested = false
                return parked
            }
            parked?.resume()
        }
    }
}

/// Check-only scheduler that parks `QueueService` at the injected hook points.
actor QueueServiceTestHook: QueueServiceHook {
    private let reset = ParkedGate()
    private let accept = ParkedGate()
    private let replacement = ParkedGate()

    func parkNextReset() { reset.parkNext() }
    func resetIsParked() -> Bool { reset.isParked() }
    func resumeReset() { reset.resume() }

    func parkNextConnectAccept() { accept.parkNext() }
    func connectAcceptIsParked() -> Bool { accept.isParked() }
    func resumeConnectAccept() { accept.resume() }

    func parkNextCommittedReplacement() { replacement.parkNext() }
    func committedReplacementIsParked() -> Bool { replacement.isParked() }
    func resumeCommittedReplacement() { replacement.resume() }

    func beforeReset() async { await reset.waitIfPending() }
    func beforeAcceptConnect() async { await accept.waitIfPending() }
    func beforeRecordCommittedReplacement() async { await replacement.waitIfPending() }
}
