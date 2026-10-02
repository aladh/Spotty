import AppKit
import CryptoKit
import Foundation
import ScreenCaptureKit
import SpottyDomain
@testable import SpottyCore

/// The full app scene is the host. This recorder samples product-owned markers and public
/// AppKit toolbar views; it never searches the internal SwiftUI view hierarchy.
@MainActor
final class BrowsingShellRegression {
    struct Rect: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ value: CGRect) {
            x = Double(value.minX)
            y = Double(value.minY)
            width = Double(value.width)
            height = Double(value.height)
        }
    }

    struct Assertion: Codable {
        let name: String
        let passed: Bool
        let expected: String
        let observed: String
    }

    struct Capture: Codable {
        let file: String
        let source: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
        let sha256: String
    }

    struct ToolbarItem: Codable {
        let identifier: String
        let frame: Rect?
    }

    struct PixelSample: Codable {
        let name: String
        let windowRect: Rect
        let pixelRect: Rect
        let pixelCount: Int
        let minimumAlpha: Int
        let maximumRGB: Int
        let meanRGB: Double
    }

    private struct WindowRaster {
        let capture: Capture
        let bitmap: NSBitmapImageRep
        let filterRect: CGRect
        let filterScale: Float
    }

    struct Checkpoint: Codable {
        let name: String
        let runID: String
        let host: String
        let sourceSHA256: String
        let buildProductSHA256: String
        let elapsedSeconds: Double
        let keyWindow: Bool
        let appActive: Bool
        let visible: Bool
        let backingScale: Double
        let windowNumber: Int
        let playing: Bool
        let commandCount: Int
        let mutationAttempts: Int
        let windowFrame: Rect
        let contentBounds: Rect
        let contentLayoutRect: Rect
        let desiredBodySize: Rect?
        let requestedBodySize: Rect?
        let screenVisibleFrame: Rect?
        let frameToBodyOverhead: Rect?
        let captureContentRect: Rect?
        let capturePointPixelScale: Double?
        let markers: [String: Rect]
        let toolbarItems: [ToolbarItem]
        let captures: [Capture]
        let pixelSamples: [PixelSample]
        let assertions: [Assertion]
    }

    struct Report: Encodable {
        let schemaVersion = 1
        let launch: BrowsingLaunch
        let host: String
        let os: String
        let captureLimit =
            "Required ScreenCaptureKit current-process capture of this synthetic window includes the native toolbar. Additional public NSView cacheDisplay images are separate diagnostic surfaces. Screenshots do not establish visual parity."
        let coordinateSpace = "NSWindow base coordinates, bottom-left origin"
        let networkSandboxVerified: Bool
        let checkpoints: [Checkpoint]
        let inspectorMenuDiagnostics: [String]
        let passed: Bool
        let failure: String?
    }

    private let launch: BrowsingLaunch
    private let networkSandboxVerified: Bool
    private let started = ContinuousClock.now
    private var checkpoints: [Checkpoint] = []
    private var inspectorMenuDiagnostics: [String] = []
    private var completed = false
    private var desiredBodySize: CGSize?
    private var requestedBodySize: CGSize?
    private var sizingScreenVisibleFrame: CGRect?
    private var capturedScreenVisibleFrame: CGRect?
    private var frameToBodyOverhead: CGSize?
    private var minimumBodySize: CGSize?
    private var shortcutChecks: Set<String> = []
    private var hitTargetChecks: Set<String> = []
    private var hitTargetFrames: [String: Rect] = [:]
    private var deadline = ContinuousClock.now
    private(set) var failure: String?

    init(launch: BrowsingLaunch, networkSandboxVerified: Bool) {
        self.launch = launch
        self.networkSandboxVerified = networkSandboxVerified
    }

    var report: Report {
        Report(
            launch: launch, host: Bundle.main.bundleIdentifier ?? "unknown",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            networkSandboxVerified: networkSandboxVerified, checkpoints: checkpoints,
            inspectorMenuDiagnostics: inspectorMenuDiagnostics,
            passed: completed && failure == nil && !checkpoints.isEmpty, failure: failure)
    }

    func run(
        player: PlaybackStore, world: BrowsingWorld, navigation: CatalogNavigation, window: NSWindow,
        sampled: (String) async throws -> Void
    ) async throws {
        deadline = ContinuousClock.now.advanced(by: .seconds(60))
        do {
            // SwiftUI must create its application before a direct-launched fixture requests activation.
            guard NSApp.activationPolicy() == .regular || NSApp.setActivationPolicy(.regular) else {
                throw BrowsingFailure.checkpoint("shell.activation-policy")
            }
            let signedOut = world.scenario.mode == .signedOut
            if !signedOut {
                try await wait("restore.paused-artwork", deadline: deadline) {
                    player.hasCurrentTrack && !player.isPlaying && player.displayedArtworkURL != nil
                        && ShellGeometry.frames(in: window)["shell.track-artwork.loaded"] != nil
                }
            }
            navigation.updateSelection(.destination(.home))
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await settle(window: window, deadline: deadline)
            for (name, size) in [
                ("default", NSSize(width: 1220, height: 780)),
                ("minimum", NSSize(width: 960, height: 640)),
            ] {
                try resize(window, bodySize: size)
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                try await settle(window: window, deadline: deadline)
                try await verifyToolbarHitTargets(window: window, navigation: navigation)
                let checkpoint = "\(signedOut ? "signed-out" : "home").\(name)"
                try await capture(checkpoint, player: player, world: world, window: window, expectedKey: true)
                if name == "minimum" {
                    minimumBodySize = CGSize(
                        width: window.contentView?.bounds.width ?? 0, height: window.contentLayoutRect.height)
                }
                try await sampled(checkpoint)
            }
            // Transfer native key ownership to an empty fixture window. Calling resignKey()
            // directly does not update AppKit's key-window bookkeeping for a later reactivation.
            let focusWindow = ShellFocusWindow(
                contentRect: CGRect(x: window.frame.minX + 8, y: window.frame.minY + 8, width: 32, height: 32),
                styleMask: [.titled], backing: .buffered, defer: false)
            focusWindow.isReleasedWhenClosed = false
            focusWindow.identifier = NSUserInterfaceItemIdentifier("spotty.gui.focus-fixture")
            defer { focusWindow.close() }
            focusWindow.makeKeyAndOrderFront(nil)
            try await wait("window.inactive", deadline: deadline) { focusWindow.isKeyWindow && !window.isKeyWindow }
            try await settle(window: window, deadline: deadline)
            try await capture("shell.inactive", player: player, world: world, window: window, expectedKey: false)
            try await sampled("shell.inactive")
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await wait("window.reactivated", deadline: deadline) { window.isKeyWindow && NSApp.isActive }
            focusWindow.orderOut(nil)
            try resize(window, bodySize: NSSize(width: 1080, height: 700))
            try await settle(window: window, deadline: deadline)
            try await verifyToolbarHitTargets(window: window, navigation: navigation)
            try await capture("shell.resized", player: player, world: world, window: window, expectedKey: true)
            try await sampled("shell.resized")
            try toggleInspector(window: window)
            try await wait("inspector.presented", deadline: min(deadline, .now.advanced(by: .seconds(5)))) {
                ShellGeometry.frames(in: window)["shell.inspector"].map { $0.width > 0 } == true
            }
            for (name, size) in [
                ("resized", NSSize(width: 1080, height: 700)),
                ("minimum", NSSize(width: 960, height: 640)),
                ("default", NSSize(width: 1220, height: 780)),
            ] {
                try resize(window, bodySize: size)
                try await settle(window: window, deadline: deadline, required: ["shell.inspector"])
                try await verifyToolbarHitTargets(window: window, navigation: navigation)
                let checkpoint = "inspector.\(name)"
                try await capture(checkpoint, player: player, world: world, window: window, expectedKey: true)
                try await sampled(checkpoint)
            }
            try toggleInspector(window: window)
            try await wait("inspector.dismissed", deadline: deadline) {
                ShellGeometry.frames(in: window)["shell.inspector"] == nil
            }
            try resize(window, bodySize: NSSize(width: 1080, height: 700))
            try await settle(window: window, deadline: deadline)
            try await verifyToolbarHitTargets(window: window, navigation: navigation)
            try await capture("inspector.closed", player: player, world: world, window: window, expectedKey: true)
            try await sampled("inspector.closed")
            if !signedOut {
                navigation.updateSelection(.destination(.search))
                navigation.searchText = "Signals"
                await player.catalog.searchStore.search("Signals")
                try await wait("search.ready", deadline: deadline) {
                    !player.catalog.searchStore.isAwaitingResults(for: "Signals")
                        && !player.catalog.searchStore.albums.isEmpty
                }
                try await settle(window: window, deadline: deadline, required: ["search.filters"])
                try await capture("search.all", player: player, world: world, window: window, expectedKey: true)
                try await sampled("search.all")
                navigation.searchInteraction.filter = .albums
                try await settle(window: window, deadline: deadline, required: ["search.filters"])
                try await capture("search.albums", player: player, world: world, window: window, expectedKey: true)
                try await sampled("search.albums")
                try await wait("detail.library-ready", deadline: deadline) {
                    !player.catalog.homeLibrary.playlists.isEmpty
                }
                guard let item = player.catalog.homeLibrary.playlists.first else {
                    throw BrowsingFailure.checkpoint("detail.fixture")
                }
                await player.catalog.playlistStore.load(item)
                navigation.select(item)
                try await wait("detail.ready", deadline: deadline) {
                    player.catalog.playlistStore.loadedURI == item.uri
                        && player.catalog.playlistStore.tracks.count == world.scenario.trackCount
                        && window.contentView.map { BrowsingRun.findPlaylistScrollView(in: $0) != nil } == true
                }
                try await settle(window: window, deadline: deadline)
                try await capture("detail.playlist", player: player, world: world, window: window, expectedKey: true)
                try await sampled("detail.playlist")
                let detailSelection = navigation.selection
                try sendHistoryKey("[", keyCode: 33, window: window)
                try await wait("history.shortcut-back", deadline: min(deadline, .now.advanced(by: .seconds(3)))) {
                    navigation.selection == .destination(.search)
                }
                shortcutChecks.insert("history.shortcut-back")
                try await settle(window: window, deadline: deadline, required: ["search.filters"])
                try sendHistoryKey("]", keyCode: 30, window: window)
                try await wait("history.shortcut-forward", deadline: min(deadline, .now.advanced(by: .seconds(3)))) {
                    navigation.selection == detailSelection
                }
                shortcutChecks.insert("history.shortcut-forward")
                try await settle(window: window, deadline: deadline)
                try sendHistoryKey("[", keyCode: 33, window: window)
                try await wait("history.shortcut-returned", deadline: min(deadline, .now.advanced(by: .seconds(3)))) {
                    navigation.selection == .destination(.search)
                }
                shortcutChecks.insert("history.shortcut-returned")
                try await settle(window: window, deadline: deadline, required: ["search.filters"])
                try await capture("search.returned", player: player, world: world, window: window, expectedKey: true)
                try await sampled("search.returned")
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BrowsingFailure.checkpoint("shell.deadline") }
            completed = true
            try write()
        } catch {
            failure = error.localizedDescription
            // Preserve observed geometry and safety state even when a readiness deadline fails.
            try? await capture(
                "failure-state", player: player, world: world, window: window, expectedKey: window.isKeyWindow)
            try? write()
            throw error
        }
    }

    /// Select the target before AppKit can constrain it. A small display may cap desired sizes,
    /// but it must support the real minimum and a distinct resize; never admit an observed clamp.
    static func targetBodySize(desired: CGSize, visibleFrame: CGRect, overhead: CGSize) throws -> CGSize {
        guard
            [
                desired.width, desired.height, visibleFrame.minX, visibleFrame.minY,
                visibleFrame.width, visibleFrame.height, overhead.width, overhead.height,
            ].allSatisfy(\.isFinite),
            desired.width >= 960, desired.height >= 640, overhead.width >= 0, overhead.height >= 0
        else { throw BrowsingFailure.checkpoint("window.display-geometry") }
        let available = CGSize(
            width: floor(visibleFrame.width - overhead.width),
            height: floor(visibleFrame.height - overhead.height))
        guard available.width >= 960, available.height >= 640 else {
            throw BrowsingFailure.checkpoint("window.display-below-minimum")
        }
        let target = CGSize(width: min(desired.width, available.width), height: min(desired.height, available.height))
        if desired == CGSize(width: 1080, height: 700),
            target.width - 960 <= 2, target.height - 640 <= 2
        {
            throw BrowsingFailure.checkpoint("window.display-cannot-exercise-resize")
        }
        return target
    }

    static func requalifyDisplayIfNeeded(
        sizedFrame: CGRect?, currentFrame: CGRect?, capturedFrame: CGRect? = nil, resize: () throws -> Void
    ) throws -> Bool {
        try validateCapturedDisplay(currentFrame: currentFrame, capturedFrame: capturedFrame)
        guard let sizedFrame else { return false }
        guard let currentFrame else { throw BrowsingFailure.checkpoint("window.display-unavailable") }
        guard sizedFrame != currentFrame else { return false }
        try resize()
        return true
    }

    static func validateCapturedDisplay(currentFrame: CGRect?, capturedFrame: CGRect?) throws {
        guard let capturedFrame else { return }
        guard currentFrame == capturedFrame else {
            throw BrowsingFailure.checkpoint("window.display-changed-after-capture")
        }
    }

    private func resize(_ window: NSWindow, bodySize: NSSize) throws {
        guard let screen = window.screen else {
            throw BrowsingFailure.checkpoint("window.display-unavailable")
        }
        let visibleFrame = screen.visibleFrame
        requestedBodySize = try Self.resizeOwnedWindow(
            window, bodySize: bodySize, visibleFrame: visibleFrame, capturedFrame: capturedScreenVisibleFrame
        ) { overhead in
            // Preserve the display prerequisite even when no target is eligible.
            desiredBodySize = bodySize
            requestedBodySize = nil
            sizingScreenVisibleFrame = visibleFrame
            frameToBodyOverhead = overhead
        }
    }

    static func resizeOwnedWindow(
        _ window: NSWindow, bodySize: CGSize, visibleFrame: CGRect, capturedFrame: CGRect?,
        didQualify: (CGSize) -> Void
    ) throws -> CGSize {
        // Every captured checkpoint must use one display baseline, including
        // explicit later resizes that would otherwise overwrite the sizing frame.
        try validateCapturedDisplay(currentFrame: visibleFrame, capturedFrame: capturedFrame)
        guard let content = window.contentView else { throw BrowsingFailure.checkpoint("shell.content-view") }
        let overhead = CGSize(
            width: window.frame.width - content.bounds.width,
            height: window.frame.height - window.contentLayoutRect.height)
        didQualify(overhead)
        let target = try Self.targetBodySize(desired: bodySize, visibleFrame: visibleFrame, overhead: overhead)
        let inset = content.bounds.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(width: target.width, height: target.height + max(0, inset)))
        // Place only the owned fixture window; AppKit still owns its controls and geometry.
        window.setFrameOrigin(
            CGPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2))
        return target
    }

    static func captureOnQualifiedDisplay<Value>(
        sizedFrame: CGRect?, capturedFrame: CGRect?, visibleFrame: @MainActor () -> CGRect?,
        operation: @MainActor () async throws -> Value
    ) async throws -> (frame: CGRect, value: Value) {
        guard let frame = visibleFrame(), frame == sizedFrame else {
            throw BrowsingFailure.checkpoint("capture.display-unqualified")
        }
        try validateCapturedDisplay(currentFrame: frame, capturedFrame: capturedFrame)
        let value = try await operation()
        // The final asynchronous capture has no later settle to catch drift.
        try validateCapturedDisplay(currentFrame: visibleFrame(), capturedFrame: frame)
        return (frame, value)
    }

    private func toggleInspector(window: NSWindow) throws {
        guard window.isKeyWindow, NSApp.isActive else {
            throw BrowsingFailure.checkpoint("inspector.shortcut-window")
        }
        // Dispatch InspectorCommands through the synthetic app's native menu, never global input.
        func inspectorMenuItems(_ menu: NSMenu) -> [String] {
            menu.update()
            return menu.items.flatMap { item in
                let own =
                    item.title.hasSuffix("Inspector")
                    ? [
                        "\(item.title): enabled=\(item.isEnabled), key=\(item.keyEquivalent), modifiers=\(item.keyEquivalentModifierMask.rawValue)"
                    ]
                    : []
                return own + (item.submenu.map(inspectorMenuItems) ?? [])
            }
        }
        NSApp.mainMenu?.update()
        if let menu = NSApp.mainMenu { inspectorMenuDiagnostics.append(contentsOf: inspectorMenuItems(menu)) }
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .control],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "i", charactersIgnoringModifiers: "i",
                isARepeat: false, keyCode: 34), NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        else { throw BrowsingFailure.checkpoint("inspector.shortcut-unhandled") }
    }

    /// AppKit asks lazily populated menus for their contents before normal dispatch.
    /// Direct synthetic key delivery must perform that public delegate preparation too.
    private func prepareCommandMenus() {
        func prepare(_ menu: NSMenu) {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items { if let submenu = item.submenu { prepare(submenu) } }
        }
        if let menu = NSApp.mainMenu { prepare(menu) }
    }

    private func sendHistoryKey(_ character: String, keyCode: UInt16, window: NSWindow) throws {
        guard window.isKeyWindow, NSApp.isActive else {
            throw BrowsingFailure.checkpoint("history.shortcut-window")
        }
        prepareCommandMenus()
        // Exercise the owned window's native key-equivalent dispatch, never global input.
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode)
        else { throw BrowsingFailure.checkpoint("history.shortcut-unhandled.\(character)") }
        NSApp.sendEvent(event)
    }

    private func verifyToolbarHitTargets(window: NSWindow, navigation: CatalogNavigation) async throws {
        hitTargetChecks.removeAll()
        hitTargetFrames.removeAll()
        for (marker, selection, label) in [
            ("shell.search", SidebarSelection.destination(.search), "toolbar.hit-target-search"),
            ("shell.home", .destination(.home), "toolbar.hit-target-home"),
            ("shell.history.back", .destination(.search), "toolbar.hit-target-back"),
            ("shell.history.forward", .destination(.home), "toolbar.hit-target-forward"),
        ] {
            guard let rect = ShellGeometry.frames(in: window)[marker] else {
                throw BrowsingFailure.checkpoint(label + ".marker")
            }
            // The lower edge is most likely to escape a baseline-anchored toolbar
            // item after correction. Route through the owned window's real hit test.
            let point = CGPoint(x: rect.midX, y: rect.minY + 6)
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
            else { throw BrowsingFailure.checkpoint(label + ".event") }
            // Native button tracking may synchronously consume mouse-up. These
            // events belong only to this synthetic process/window, never global input.
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            try await wait(label, deadline: min(deadline, .now.advanced(by: .seconds(3)))) {
                navigation.selection == selection
            }
            hitTargetChecks.insert(label)
            hitTargetFrames[marker] = Rect(rect)
            try await settle(window: window, deadline: deadline)
        }
        // Exercise Command-L through the app's native event dispatch, including
        // query selection after focus leaves the toolbar.
        navigation.searchText = "Signals"
        try await settle(window: window, deadline: deadline)
        window.makeFirstResponder(nil)
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "l", charactersIgnoringModifiers: "l",
                isARepeat: false, keyCode: 37)
        else { throw BrowsingFailure.checkpoint("toolbar.shortcut-search.unhandled") }
        NSApp.sendEvent(event)
        do {
            try await wait("toolbar.shortcut-search", deadline: min(deadline, .now.advanced(by: .seconds(3)))) {
                guard let editor = window.firstResponder as? NSTextView else { return false }
                return navigation.selection == .destination(.search) && editor.isFieldEditor
                    && editor.string == "Signals" && editor.selectedRange() == NSRange(location: 0, length: 7)
            }
        } catch {
            let editor = window.firstResponder as? NSTextView
            inspectorMenuDiagnostics.append(
                "Search command responder=\(String(describing: window.firstResponder.map { type(of: $0) })), fieldEditor=\(editor?.isFieldEditor ?? false), text=\(editor?.string ?? "nil"), selected=\(String(describing: editor?.selectedRange())), route=\(navigation.selection)"
            )
            throw error
        }
        shortcutChecks.insert("toolbar.shortcut-search")
        // Repeated Command-L selects the query without replacing the active editor.
        let focusedEditor = window.firstResponder
        NSApp.sendEvent(event)
        try await wait(
            "toolbar.shortcut-search-already-focused", deadline: min(deadline, .now.advanced(by: .seconds(3)))
        ) {
            guard let editor = window.firstResponder as? NSTextView else { return false }
            return window.firstResponder === focusedEditor && navigation.selection == .destination(.search)
                && editor.string == "Signals" && editor.selectedRange() == NSRange(location: 0, length: 7)
        }
        shortcutChecks.insert("toolbar.shortcut-search-already-focused")
        // Leaving Search can blur its editor. Command-L must restore the route and
        // selection whether that native focus transition has already completed or not.
        try sendHistoryKey("[", keyCode: 33, window: window)
        try await wait("toolbar.search-focused-history", deadline: min(deadline, .now.advanced(by: .seconds(3)))) {
            navigation.selection == .destination(.home)
        }
        NSApp.sendEvent(event)
        try await wait(
            "toolbar.shortcut-search-after-history", deadline: min(deadline, .now.advanced(by: .seconds(3)))
        ) {
            guard let editor = window.firstResponder as? NSTextView else { return false }
            return navigation.selection == .destination(.search) && editor.isFieldEditor
                && editor.string == "Signals" && editor.selectedRange() == NSRange(location: 0, length: 7)
        }
        shortcutChecks.insert("toolbar.shortcut-search-after-history")
        navigation.searchText = ""
        navigation.updateSelection(.destination(.home))
        try await settle(window: window, deadline: deadline)
    }

    private func settle(window: NSWindow, deadline: ContinuousClock.Instant, required: [String] = []) async throws {
        var previous: [String: Rect] = [:]
        var previousVisibleFrame: CGRect?
        var stableSince = ContinuousClock.now
        try await wait("shell.geometry-ready", deadline: deadline) {
            guard let visibleFrame = window.screen?.visibleFrame else {
                previous = [:]
                previousVisibleFrame = nil
                stableSince = .now
                return false
            }
            // Dock/work-area transitions can complete after fixture sizing. Resize
            // only our window before its first capture, then require fresh stability.
            if let desiredBodySize,
                try Self.requalifyDisplayIfNeeded(
                    sizedFrame: sizingScreenVisibleFrame, currentFrame: visibleFrame,
                    capturedFrame: capturedScreenVisibleFrame,
                    resize: { try resize(window, bodySize: desiredBodySize) })
            {
                previous = [:]
                previousVisibleFrame = nil
                stableSince = .now
                return false
            }
            let frames = ShellGeometry.frames(in: window)
            guard
                (["shell.sidebar", "shell.catalog", "shell.player", "shell.navigation"] + required)
                    .allSatisfy({ frames[$0].map { $0.width > 0 && $0.height > 0 } == true })
            else { return false }
            let current = frames.mapValues(Rect.init)
            if current != previous || visibleFrame != previousVisibleFrame {
                previous = current
                previousVisibleFrame = visibleFrame
                stableSince = .now
                return false
            }
            return stableSince.duration(to: .now) >= .milliseconds(250)
        }
    }

    private func wait(
        _ checkpoint: String, deadline: ContinuousClock.Instant, ready: () throws -> Bool
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BrowsingFailure.checkpoint(checkpoint) }
            if try ready() { return }
            try await ContinuousClock().sleep(for: .milliseconds(40))
        }
    }

    private func capture(
        _ name: String, player: PlaybackStore, world: BrowsingWorld, window: NSWindow, expectedKey: Bool
    ) async throws {
        if name != "failure-state" {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BrowsingFailure.checkpoint("shell.deadline") }
        }
        guard let content = window.contentView else { throw BrowsingFailure.checkpoint("shell.content-view") }
        var frames = ShellGeometry.frames(in: window)
        if name == "detail.playlist", let scroll = BrowsingRun.findPlaylistScrollView(in: content) {
            frames["detail.native-scroll"] = scroll.convert(scroll.bounds, to: nil)
        }
        var assertions: [Assertion] = []
        func check(_ label: String, _ passed: Bool, expected: String, observed: String) {
            assertions.append(Assertion(name: label, passed: passed, expected: expected, observed: observed))
        }
        let contentFrame = content.convert(content.bounds, to: nil)
        let tolerance: CGFloat = 2
        for (label, marker) in [
            ("toolbar.hit-target-search", "shell.search"), ("toolbar.hit-target-home", "shell.home"),
            ("toolbar.hit-target-back", "shell.history.back"), ("toolbar.hit-target-forward", "shell.history.forward"),
        ] {
            check(
                label, hitTargetChecks.contains(label) && frames[marker].map(Rect.init) == hitTargetFrames[marker],
                expected:
                    "Lower-edge native input was verified at this control's current geometry in the active window",
                observed:
                    "verified=\(String(describing: hitTargetFrames[marker])), captured=\(String(describing: frames[marker].map(Rect.init)))"
            )
        }
        check(
            "toolbar.shortcut-search", shortcutChecks.contains("toolbar.shortcut-search"),
            expected: "Owned Command-L focused the native editor and selected its query",
            observed: String(shortcutChecks.contains("toolbar.shortcut-search")))
        check(
            "toolbar.shortcut-search-already-focused",
            shortcutChecks.contains("toolbar.shortcut-search-already-focused"),
            expected: "Repeated Command-L preserved the active native editor and selected its query",
            observed: String(shortcutChecks.contains("toolbar.shortcut-search-already-focused")))
        check(
            "toolbar.shortcut-search-after-history",
            shortcutChecks.contains("toolbar.shortcut-search-after-history"),
            expected: "Command-L restored Search and selected its query after native history navigation",
            observed: String(shortcutChecks.contains("toolbar.shortcut-search-after-history")))
        if let requestedBodySize {
            check(
                "window.requested-body-size",
                abs(content.bounds.width - requestedBodySize.width) <= tolerance
                    && abs(window.contentLayoutRect.height - requestedBodySize.height) <= tolerance,
                expected: "\(requestedBodySize.width)x\(requestedBodySize.height)pt root body",
                observed: "\(content.bounds.width)x\(window.contentLayoutRect.height)pt")
        }
        if name == "shell.resized" {
            check(
                "window.distinct-resize",
                minimumBodySize.map {
                    abs(content.bounds.width - $0.width) > tolerance
                        || abs(window.contentLayoutRect.height - $0.height) > tolerance
                } == true,
                expected: "An observed body dimension changes by more than 2pt from minimum",
                observed: "\(content.bounds.width)x\(window.contentLayoutRect.height)pt")
        }
        if let sizingScreenVisibleFrame {
            check(
                "window.display-stable", window.screen?.visibleFrame == sizingScreenVisibleFrame,
                expected: "Display geometry unchanged since sizing: \(NSStringFromRect(sizingScreenVisibleFrame))",
                observed: window.screen.map { NSStringFromRect($0.visibleFrame) } ?? "Display unavailable")
            check(
                "window.fits-display",
                sizingScreenVisibleFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(window.frame),
                expected: "Native window fits the visible display", observed: NSStringFromRect(window.frame))
        }
        if name == "search.returned" {
            for label in ["history.shortcut-back", "history.shortcut-forward", "history.shortcut-returned"] {
                check(
                    label, shortcutChecks.contains(label), expected: "Owned native event navigated the expected route",
                    observed: String(shortcutChecks.contains(label)))
            }
        }
        for id in [
            "shell.sidebar", "shell.catalog", "shell.player", "shell.navigation", "shell.home", "shell.search",
            "shell.history.back", "shell.history.forward",
        ] {
            let frame = frames[id] ?? .zero
            check(
                "\(id).visible",
                frame.width > 0 && frame.height > 0
                    && contentFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(frame),
                expected: "Nonempty and contained by window content", observed: NSStringFromRect(frame))
        }
        if let sidebar = frames["shell.sidebar"], let catalog = frames["shell.catalog"],
            let shelf = frames["shell.player"], let toolbar = frames["shell.navigation"]
        {
            check(
                "sidebar.width", (180 - tolerance...260 + tolerance).contains(sidebar.width),
                expected: "180...260pt", observed: "\(sidebar.width)")
            check(
                "catalog.excludes-sidebar", sidebar.maxX <= catalog.minX + tolerance,
                expected: "Sidebar ends before catalog", observed: "\(sidebar.maxX), \(catalog.minX)")
            check(
                "player.excludes-catalog", shelf.maxY <= catalog.minY + tolerance,
                expected: "Player below catalog", observed: "\(shelf.maxY), \(catalog.minY)")
            check(
                "toolbar.excludes-catalog", catalog.maxY <= toolbar.minY + tolerance,
                expected: "Toolbar above catalog", observed: "\(catalog.maxY), \(toolbar.minY)")
            check(
                "player.height", shelf.height >= 72 - tolerance,
                expected: "At least 72pt", observed: "\(shelf.height)")
        }
        if let navigation = frames["shell.navigation"] {
            check(
                "toolbar.group-centered", abs(navigation.midX - contentFrame.midX) <= tolerance,
                expected: "Home and Search group centered across the entire window, including inspector",
                observed: "group=\(navigation.midX), window=\(contentFrame.midX)")
        }
        let expectsInspector = name.hasPrefix("inspector.") && name != "inspector.closed"
        let inspector = frames["shell.inspector"]
        check(
            "inspector.presentation", expectsInspector == (inspector.map { $0.width > 0 } == true),
            expected: "Inspector presented=\(expectsInspector)", observed: inspector.map(NSStringFromRect) ?? "absent")
        if expectsInspector, let inspector, let catalog = frames["shell.catalog"] {
            check(
                "inspector.excludes-catalog", catalog.maxX <= inspector.minX + tolerance,
                expected: "Inspector follows catalog without overlap",
                observed: "catalog=\(catalog.maxX), inspector=\(inspector.minX)")
        }
        if let home = frames["shell.home"], let search = frames["shell.search"] {
            let rowHeight = contentFrame.maxY - window.contentLayoutRect.maxY
            check(
                "toolbar.row-height", abs(rowHeight - 64) <= tolerance,
                expected: "Spotify's 64pt row, allowing the native unified label row's 2pt difference",
                observed: "\(rowHeight)")
            check(
                "toolbar.control-margins",
                [home, search].allSatisfy {
                    abs(contentFrame.maxY - $0.maxY - 8) <= tolerance
                        && abs($0.minY - window.contentLayoutRect.maxY - 8) <= tolerance
                },
                expected: "48pt controls with 8pt top/bottom margins (native tolerance 2pt)",
                observed: "home=\(NSStringFromRect(home)), search=\(NSStringFromRect(search))")
            check(
                "toolbar.controls-disjoint", !home.intersects(search),
                expected: "Home and Search do not overlap",
                observed: "\(NSStringFromRect(home)), \(NSStringFromRect(search))")
            check(
                "toolbar.search-height", abs(search.height - 48) <= tolerance,
                expected: "48pt", observed: "\(search.height)")
            check(
                "toolbar.home-size", abs(home.width - 48) <= tolerance && abs(home.height - 48) <= tolerance,
                expected: "48x48pt", observed: NSStringFromRect(home))
            check(
                "toolbar.search-width", abs(search.width - min(474, contentFrame.width / 2 - 72)) <= tolerance,
                expected: "Capsule max474pt, shrinking with full-window width",
                observed: "\(search.width) at windowWidth=\(contentFrame.width)")
            check(
                "toolbar.control-alignment",
                abs(home.midY - search.midY) <= tolerance
                    && abs(search.minX - home.maxX - 8) <= tolerance,
                expected: "Common vertical center and 8pt Home/Search gap",
                observed: "homeY=\(home.midY), searchY=\(search.midY), gap=\(search.minX - home.maxX)")
        }
        for (controlID, glyphID) in [
            ("shell.home", "shell.home.glyph"), ("shell.search", "shell.search.glyph"),
        ] {
            let control = frames[controlID] ?? .zero
            let glyph = frames[glyphID] ?? .zero
            check(
                "\(glyphID).aligned",
                abs(glyph.width - 24) <= tolerance && abs(glyph.height - 24) <= tolerance
                    && abs(glyph.midY - control.midY) <= tolerance && control.contains(glyph)
                    && (controlID == "shell.home"
                        ? abs(glyph.midX - control.midX) <= tolerance
                        : abs(glyph.minX - control.minX - 12) <= tolerance),
                expected: "24pt glyph vertically centered with matching inset",
                observed: "control=\(NSStringFromRect(control)), glyph=\(NSStringFromRect(glyph))")
        }
        if let search = frames["shell.search"], let field = frames["shell.search.field"] {
            check(
                "toolbar.search-field-inset", search.contains(field) && abs(field.minX - search.minX - 48) <= tolerance,
                expected: "Native search text field starts 48pt inside the capsule",
                observed: "search=\(NSStringFromRect(search)), field=\(NSStringFromRect(field))")
        } else {
            check("toolbar.search-field-inset", false, expected: "Native search field marker", observed: "Missing")
        }
        for id in ["shell.history.back", "shell.history.forward"] {
            let frame = frames[id] ?? .zero
            check(
                "\(id).hitbox-size", abs(frame.width - 32) <= tolerance && abs(frame.height - 32) <= tolerance,
                expected: "32x32pt history arrow hitbox", observed: NSStringFromRect(frame))
        }
        if let back = frames["shell.history.back"], let forward = frames["shell.history.forward"],
            let navigation = frames["shell.navigation"]
        {
            check(
                "toolbar.history-alignment",
                abs(forward.midX - back.midX - 34) <= tolerance
                    && abs(back.midY - forward.midY) <= tolerance
                    && frames["shell.home"].map { abs(back.midY - $0.midY) <= tolerance } == true,
                expected: "History arrow centers 34pt apart on the same row",
                observed: "back=\(NSStringFromRect(back)), forward=\(NSStringFromRect(forward))")
            check(
                "toolbar.history-controls-disjoint",
                !back.intersects(forward)
                    && !back.intersects(navigation) && !forward.intersects(navigation),
                expected: "History arrows do not overlap each other or Home/Search",
                observed:
                    "back=\(NSStringFromRect(back)), forward=\(NSStringFromRect(forward)), navigation=\(NSStringFromRect(navigation))"
            )
        }
        if let filters = frames["search.filters"], let catalog = frames["shell.catalog"] {
            check(
                "search.filters-contained", catalog.insetBy(dx: -tolerance, dy: -tolerance).contains(filters),
                expected: "Search filters inside catalog", observed: NSStringFromRect(filters))
        }
        if name == "detail.playlist" {
            let frame = frames["detail.native-scroll"] ?? .zero
            let catalog = frames["shell.catalog"] ?? .zero
            check(
                "detail.native-scroll-contained",
                frame.width > 0 && frame.height > 0
                    && catalog.insetBy(dx: -tolerance, dy: -tolerance).contains(frame),
                expected: "Attached native detail scroll surface inside catalog", observed: NSStringFromRect(frame))
        }
        check(
            "window.key-state", window.isKeyWindow == expectedKey,
            expected: "\(expectedKey)", observed: "\(window.isKeyWindow)")
        check(
            "window.application-active-state", NSApp.isActive,
            expected: "Active fixture application; key-window state is tested separately", observed: "\(NSApp.isActive)"
        )
        check(
            "safety.no-playing", !player.isPlaying && !world.playback.snapshot().playing,
            expected: "Paused", observed: "store=\(player.isPlaying), fixture=\(world.playback.snapshot().playing)")
        check(
            "safety.no-commands", world.playback.snapshot().commandCount == 0 && world.snapshot().mutationAttempts == 0,
            expected: "0 commands,0 mutations",
            observed: "\(world.playback.snapshot().commandCount), \(world.snapshot().mutationAttempts)")
        if world.scenario.mode != .signedOut {
            check(
                "restore.current-track-artwork", player.hasCurrentTrack && frames["shell.track-artwork.loaded"] != nil,
                expected: "Restored track with loaded artwork",
                observed: "track=\(player.hasCurrentTrack), artwork=\(frames["shell.track-artwork.loaded"] != nil)")
        } else {
            check(
                "signed-out.no-engine", (world.snapshot().requests["engine.synthetic-initialize"] ?? 0) == 0,
                expected: "0 engine initializations",
                observed: "\(world.snapshot().requests["engine.synthetic-initialize"] ?? 0)")
        }
        var captures: [Capture] = []
        var pixelSamples: [PixelSample] = []
        var captureContentRect: Rect?
        var capturePointPixelScale: Double?
        do {
            let raster: WindowRaster
            if name == "failure-state" {
                raster = try await windowPNG(window, name: "\(name).window.png")
            } else {
                let capture = try await Self.captureOnQualifiedDisplay(
                    sizedFrame: sizingScreenVisibleFrame, capturedFrame: capturedScreenVisibleFrame,
                    visibleFrame: { window.screen?.visibleFrame },
                    operation: { try await windowPNG(window, name: "\(name).window.png") })
                capturedScreenVisibleFrame = capturedScreenVisibleFrame ?? capture.frame
                raster = capture.value
            }
            if name != "failure-state" {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw BrowsingFailure.checkpoint("capture.deadline") }
            }
            captures.append(raster.capture)
            captureContentRect = Rect(raster.filterRect)
            capturePointPixelScale = Double(raster.filterScale)
            check(
                "capture.window-dimensions",
                abs(raster.filterRect.width - window.frame.width) <= tolerance
                    && abs(raster.filterRect.height - window.frame.height) <= tolerance,
                expected: "Own-window capture covers the complete window frame",
                observed: NSStringFromRect(raster.filterRect))
            for id in ["shell.home", "shell.search"] {
                guard let navigation = frames["shell.navigation"], let control = frames[id] else { continue }
                let inset: CGFloat = id == "shell.home" ? 8 : 24
                let padding = control.minY - navigation.minY
                let region = CGRect(
                    x: control.minX + inset, y: navigation.minY + padding / 4,
                    width: control.width - inset * 2, height: min(4, padding / 2))
                let valid =
                    padding >= 2 && region.width > 0 && region.height > 0
                    && navigation.contains(region) && !region.intersects(control)
                check(
                    "\(id).chrome-sample-region", valid,
                    expected: "Nonempty padding strip inside navigation and outside controls",
                    observed: NSStringFromRect(region))
                guard valid else { continue }
                let sample = try samplePixels(raster.bitmap, windowSize: window.frame.size, region: region, name: id)
                pixelSamples.append(sample)
                check(
                    "\(id).chrome-opaque", sample.minimumAlpha >= 250,
                    expected: "Opaque window chrome, alpha minimum >=250/255",
                    observed: "alpha minimum=\(sample.minimumAlpha), pixels=\(sample.pixelCount)")
                check(
                    "\(id).native-background-does-not-cover-padding", sample.maximumRGB <= 12,
                    expected: "Black window chrome padding, RGB maximum <=12/255",
                    observed: "max=\(sample.maximumRGB), mean=\(sample.meanRGB), pixels=\(sample.pixelCount)")
            }
            for id in ["shell.history.back", "shell.history.forward"] {
                guard let control = frames[id] else { continue }
                // History arrows use a centered symbol in their 32pt hitbox. This thin
                // interior edge is outside the centered 14x16pt glyph allowance.
                let region = CGRect(x: control.minX + 2, y: control.midY - 6, width: 2, height: 12)
                let glyphAllowance = CGRect(x: control.midX - 7, y: control.midY - 8, width: 14, height: 16)
                let valid = control.contains(region) && !region.intersects(glyphAllowance)
                check(
                    "\(id).chrome-sample-region", valid,
                    expected: "Nonempty interior edge strip outside centered arrow glyph",
                    observed: NSStringFromRect(region))
                guard valid else { continue }
                let sample = try samplePixels(raster.bitmap, windowSize: window.frame.size, region: region, name: id)
                pixelSamples.append(sample)
                check(
                    "\(id).chrome-opaque", sample.minimumAlpha >= 250,
                    expected: "Opaque history arrow edge, alpha minimum >=250/255",
                    observed: "alpha minimum=\(sample.minimumAlpha), pixels=\(sample.pixelCount)")
                check(
                    "\(id).native-background-does-not-cover-edge", sample.maximumRGB <= 12,
                    expected: "Black history arrow edge, RGB maximum <=12/255",
                    observed: "max=\(sample.maximumRGB), mean=\(sample.meanRGB), pixels=\(sample.pixelCount)")
            }
        } catch {
            check(
                "capture.own-window", false, expected: "Required current-process composite PNG",
                observed: error.localizedDescription)
        }
        do {
            captures.append(try png(content, name: "\(name).content.png", source: "NSWindow.contentView.cacheDisplay"))
        } catch {
            check(
                "capture.diagnostic-content", false, expected: "Public content-view diagnostic PNG",
                observed: error.localizedDescription)
        }
        var toolbarItems: [ToolbarItem] = []
        for (index, item) in (window.toolbar?.visibleItems ?? []).enumerated() {
            toolbarItems.append(
                ToolbarItem(
                    identifier: item.itemIdentifier.rawValue,
                    frame: item.view.map { Rect($0.convert($0.bounds, to: nil)) }))
            if let view = item.view, view.bounds.width > 0, view.bounds.height > 0 {
                do {
                    captures.append(
                        try png(
                            view, name: "\(name).toolbar-\(index).png",
                            source: "NSToolbar.visibleItems[\(index)].view.cacheDisplay"))
                } catch {
                    check(
                        "capture.diagnostic-toolbar-\(index)", false, expected: "Public toolbar diagnostic PNG",
                        observed: error.localizedDescription)
                }
            }
        }
        let elapsed = started.duration(to: .now).components
        checkpoints.append(
            Checkpoint(
                name: name, runID: launch.runID, host: Bundle.main.bundleIdentifier ?? "unknown",
                sourceSHA256: launch.source.sourceSHA256, buildProductSHA256: launch.build.buildProductSHA256,
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                keyWindow: window.isKeyWindow, appActive: NSApp.isActive,
                visible: window.occlusionState.contains(.visible),
                backingScale: Double(window.backingScaleFactor), windowNumber: window.windowNumber,
                playing: player.isPlaying,
                commandCount: world.playback.snapshot().commandCount,
                mutationAttempts: world.snapshot().mutationAttempts,
                windowFrame: Rect(window.frame),
                contentBounds: Rect(content.bounds), contentLayoutRect: Rect(window.contentLayoutRect),
                desiredBodySize: desiredBodySize.map { Rect(CGRect(origin: .zero, size: $0)) },
                requestedBodySize: requestedBodySize.map { Rect(CGRect(origin: .zero, size: $0)) },
                screenVisibleFrame: sizingScreenVisibleFrame.map(Rect.init),
                frameToBodyOverhead: frameToBodyOverhead.map { Rect(CGRect(origin: .zero, size: $0)) },
                captureContentRect: captureContentRect, capturePointPixelScale: capturePointPixelScale,
                markers: frames.mapValues(Rect.init), toolbarItems: toolbarItems, captures: captures,
                pixelSamples: pixelSamples,
                assertions: assertions))
        try write()
        if let failed = assertions.first(where: { !$0.passed }) {
            throw BrowsingFailure.checkpoint("\(name).\(failed.name)")
        }
    }

    private func png(_ view: NSView, name: String, source: String) throws -> Capture {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw BrowsingFailure.checkpoint("capture.\(name)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try save(bitmap, name: name, source: source)
    }

    private func windowPNG(_ window: NSWindow, name: String) async throws -> WindowRaster {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var selected: SCWindow?
        while selected == nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BrowsingFailure.checkpoint("capture.resize-ready") }
            let available = try await SCShareableContent.currentProcess
            guard let shared = available.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
                shared.owningApplication.map({ $0.processID == ownPID }) ?? true
            else { throw BrowsingFailure.checkpoint("capture.own-window") }
            // Layout can settle before WindowServer publishes its new capture bounds.
            if abs(shared.frame.width - window.frame.width) <= 1 && abs(shared.frame.height - window.frame.height) <= 1
            {
                selected = shared
            } else {
                try await ContinuousClock().sleep(for: .milliseconds(50))
            }
        }
        guard let shared = selected else { throw BrowsingFailure.checkpoint("capture.own-window") }
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * window.backingScaleFactor).rounded())
        configuration.height = Int((window.frame.height * window.backingScaleFactor).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        let filter = SCContentFilter(desktopIndependentWindow: shared)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        return WindowRaster(
            capture: try save(
                bitmap, name: name, source: "ScreenCaptureKit.currentProcess.own-window.\(window.windowNumber)"),
            bitmap: bitmap, filterRect: filter.contentRect, filterScale: filter.pointPixelScale)
    }

    private func samplePixels(_ bitmap: NSBitmapImageRep, windowSize: CGSize, region: CGRect, name: String) throws
        -> PixelSample
    {
        let scaleX = CGFloat(bitmap.pixelsWide) / windowSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / windowSize.height
        let pixels = CGRect(
            x: (region.minX * scaleX).rounded(.up), y: (CGFloat(bitmap.pixelsHigh) - region.maxY * scaleY).rounded(.up),
            width: (region.width * scaleX).rounded(.down), height: (region.height * scaleY).rounded(.down))
        guard pixels.width > 0, pixels.height > 0,
            CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).contains(pixels)
        else { throw BrowsingFailure.checkpoint("capture.pixel-region.\(name)") }
        var maximum = 0
        var minimumAlpha = 255
        var sum = 0
        var count = 0
        for y in Int(pixels.minY)..<Int(pixels.maxY) {
            for x in Int(pixels.minX)..<Int(pixels.maxX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    throw BrowsingFailure.checkpoint("capture.pixel-color.\(name)")
                }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent].map {
                    Int(($0 * 255).rounded())
                }
                maximum = max(maximum, channels.max() ?? 0)
                minimumAlpha = min(minimumAlpha, Int((color.alphaComponent * 255).rounded()))
                sum += channels.reduce(0, +)
                count += 1
            }
        }
        return PixelSample(
            name: name, windowRect: Rect(region), pixelRect: Rect(pixels), pixelCount: count,
            minimumAlpha: minimumAlpha, maximumRGB: maximum, meanRGB: Double(sum) / Double(count * 3))
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String, source: String) throws -> Capture {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowsingFailure.checkpoint("capture.\(name)")
        }
        let directory = URL(fileURLWithPath: launch.runRoot).appendingPathComponent("shell-captures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return Capture(
            file: "shell-captures/\(name)", source: source, pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: launch.runRoot).appendingPathComponent("shell-regression.json"), options: .atomic)
    }
}

@MainActor
private final class ShellFocusWindow: NSWindow {
    override var canBecomeMain: Bool { false }
}
