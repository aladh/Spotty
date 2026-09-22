@testable import SpottyCore

@MainActor
final class HarnessSystemMediaOutput: SystemMediaControlsOutput {
    var handler: (@MainActor @Sendable (SystemMediaCommand) -> Bool)?
    var snapshot: SystemMediaSnapshot?
    var installations = 0
    var removals = 0
    func install(_ handler: @escaping @MainActor @Sendable (SystemMediaCommand) -> Bool) {
        self.handler = handler
        installations += 1
    }
    func update(_ snapshot: SystemMediaSnapshot?) { self.snapshot = snapshot }
    func remove() { removals += 1; snapshot = nil }
}
