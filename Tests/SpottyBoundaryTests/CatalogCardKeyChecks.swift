import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Catalog card key activation")
@MainActor
struct CatalogCardKeyChecks {
    @Test func spaceActivatesOnceAndConsumesRepeatsAndRelease() {
        var activations = 0
        for phase: KeyPress.Phases in [.down, .repeat, .repeat, .up] {
            #expect(CatalogCardKeyHandling.phases.contains(phase))
            let result = CatalogCardKeyHandling.handle(
                phase: phase, modifiers: [], isEnabled: true, action: { activations += 1 })
            #expect(result == .handled)
        }
        #expect(activations == 1)
        _ = CatalogCardKeyHandling.handle(
            phase: .down, modifiers: .capsLock, isEnabled: true, action: { activations += 1 })
        #expect(activations == 2)
    }

    @Test func disabledAndModifiedKeysDoNotActivateOrConsumeNativeShortcuts() {
        var activations = 0
        let action = { activations += 1 }
        for phase: KeyPress.Phases in [.down, .repeat, .up] {
            #expect(
                CatalogCardKeyHandling.handle(
                    phase: phase, modifiers: [], isEnabled: false, action: action) == .ignored)
            for modifiers: EventModifiers in [.command, .control, .option, .shift] {
                #expect(
                    CatalogCardKeyHandling.handle(
                        phase: phase, modifiers: modifiers, isEnabled: true, action: action) == .ignored)
            }
        }
        #expect(activations == 0)
    }
}
