import AppKit

/// Public in-process AX objects only; never inspect SwiftUI's private view classes.
@MainActor
enum HomePresentedAccessibilityProbe {
    struct Result {
        let control: (any NSAccessibilityProtocol)?
        let evidence: [String: Any]
    }

    static func discover(in root: Any, visibleFrame: NSRect, label: String, limit: Int = 10_000) -> Result {
        var pending: [Any] = [root]
        var inspected = 0
        var unsupported = 0
        var buttons = 0
        var samples: [[String: Any]] = []
        var selected: (any NSAccessibilityProtocol)?
        while let element = pending.popLast(), inspected < limit {
            inspected += 1
            guard let accessible = element as? any NSAccessibilityProtocol else {
                unsupported += 1
                continue
            }
            if accessible.accessibilityRole() == .button {
                buttons += 1
                let title = accessible.accessibilityLabel() ?? ""
                let enabled = accessible.isAccessibilityEnabled()
                let visible = accessible.accessibilityFrame().intersects(visibleFrame)
                if samples.count < 16 {
                    samples.append(["label": title, "enabled": enabled, "frameIntersectsWindow": visible])
                }
                if title == label && enabled && visible {
                    selected = accessible
                    break
                }
            }
            pending.append(contentsOf: (accessible.accessibilityChildren() ?? []).reversed())
        }
        return Result(
            control: selected,
            evidence: [
                "inspectedElements": inspected, "unsupportedElements": unsupported,
                "buttonCount": buttons, "buttonSamples": samples, "targetLabel": label,
                "targetFound": selected != nil, "limitReached": inspected >= limit && selected == nil,
            ])
    }
}
