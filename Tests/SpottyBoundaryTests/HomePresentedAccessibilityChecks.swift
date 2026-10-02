import AppKit
import Testing

@MainActor
struct HomePresentedAccessibilityChecks {
    @Test func exactVisibleEnabledTargetDoesNotDependOnTraversalOrder() throws {
        let viewport = NSRect(x: 0, y: 0, width: 900, height: 600)
        let visible = NSRect(x: 20, y: 20, width: 100, height: 50)
        let other = button("Synthetic album 0-7", frame: visible)
        let disabled = button("Synthetic album 0-0", frame: visible, enabled: false)
        let offscreen = button("Synthetic album 0-0", frame: NSRect(x: 20, y: 900, width: 100, height: 50))
        let target = button("Synthetic album 0-0", frame: visible)
        let root = NSAccessibilityElement()
        root.setAccessibilityRole(.group)
        root.setAccessibilityChildren([NSObject(), other, disabled, offscreen, target])
        let result = HomePresentedAccessibilityProbe.discover(
            in: root, visibleFrame: viewport, label: "Synthetic album 0-0")
        let selected = try #require(result.control)
        #expect(selected as AnyObject === target)
        #expect(selected.accessibilityPerformPress())
        #expect(target.pressCount == 1 && other.pressCount == 0)
        #expect(disabled.pressCount == 0 && offscreen.pressCount == 0)
        #expect(result.evidence["unsupportedElements"] as? Int == 1)
    }

    @Test func absentTargetPreservesBoundedDiscoveryEvidence() {
        let root = NSAccessibilityElement()
        root.setAccessibilityRole(.group)
        root.setAccessibilityChildren((0..<8).map { button("Other \($0)", frame: .zero) })
        let result = HomePresentedAccessibilityProbe.discover(
            in: root, visibleFrame: NSRect(x: 0, y: 0, width: 900, height: 600),
            label: "Synthetic album 0-0", limit: 4)
        #expect(result.control == nil)
        #expect(result.evidence["inspectedElements"] as? Int == 4)
        #expect(result.evidence["limitReached"] as? Bool == true)
    }

    private func button(_ label: String, frame: NSRect, enabled: Bool = true) -> ProbeButton {
        let element = ProbeButton()
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel(label)
        element.setAccessibilityFrame(frame)
        element.setAccessibilityEnabled(enabled)
        return element
    }
}

/// Harness service fakes cannot vend public AppKit AX objects or observe their press action.
@MainActor
private final class ProbeButton: NSAccessibilityElement {
    var pressCount = 0
    override func accessibilityPerformPress() -> Bool {
        pressCount += 1
        return true
    }
}
