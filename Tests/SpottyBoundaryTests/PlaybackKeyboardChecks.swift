import AppKit
import Testing
@testable import SpottyCore

@Suite("Playback keyboard controls")
@MainActor
struct PlaybackKeyboardChecks {
    @Test func spaceAdmissionAndLifetime() throws {
        var allowed = true
        var toggles = 0
        let controls = PlaybackKeyboardControls(canToggle: { allowed }, toggle: { toggles += 1 })
        let space = try event()
        #expect(!controls.handle(space, firstResponder: nil, isPlaybackWindow: true))
        controls.start()
        controls.start()
        defer { controls.stop() }
        #expect(controls.isRunning)
        #expect(controls.handle(space, firstResponder: NSTableView(), isPlaybackWindow: true))
        #expect(toggles == 1)
        #expect(controls.handle(try event(repeatKey: true), firstResponder: nil, isPlaybackWindow: true))
        #expect(toggles == 1)
        allowed = false
        #expect(controls.handle(try event(repeatKey: true), firstResponder: nil, isPlaybackWindow: true))
        #expect(toggles == 1)
        #expect(!controls.handle(try event(type: .keyUp), firstResponder: nil, isPlaybackWindow: true))
        #expect(!controls.handle(try event(repeatKey: true), firstResponder: nil, isPlaybackWindow: true))
        #expect(!controls.handle(space, firstResponder: nil, isPlaybackWindow: true))
        #expect(toggles == 1)
        controls.stop()
        controls.stop()
        #expect(!controls.isRunning)
        allowed = true
        #expect(!controls.handle(space, firstResponder: nil, isPlaybackWindow: true))
        #expect(toggles == 1)
    }

    @Test func preservesEditingControlsAndOtherShortcuts() throws {
        var toggles = 0
        let controls = PlaybackKeyboardControls(canToggle: { true }, toggle: { toggles += 1 })
        controls.start()
        defer { controls.stop() }
        let space = try event()
        for responder in [NSTextView(), NSTextField(), NSButton(), NSSlider()] as [NSResponder] {
            #expect(!controls.handle(space, firstResponder: responder, isPlaybackWindow: true))
        }
        #expect(!controls.handle(space, firstResponder: nil, isPlaybackWindow: false))
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift, .function] {
            #expect(!controls.handle(try event(flags: flags), firstResponder: nil, isPlaybackWindow: true))
        }
        #expect(!controls.handle(try event(characters: "x"), firstResponder: nil, isPlaybackWindow: true))
        for role: NSAccessibility.Role in [.button, .textField, .textArea, .slider, .comboBox] {
            #expect(
                !controls.handle(
                    space, firstResponder: NSView(), isPlaybackWindow: true, focusedRole: role
                ))
        }
        #expect(toggles == 0)
        #expect(
            controls.handle(
                try event(flags: .capsLock), firstResponder: nil, isPlaybackWindow: true, focusedRole: .row
            ))
        #expect(toggles == 1)
    }

    private func event(
        characters: String = " ", flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false,
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: 49
            ))
    }
}
