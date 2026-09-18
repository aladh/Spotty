import AppKit
import SwiftUI
import Testing
@testable import SpottyCore

@Suite("Home shortcut layout")
@MainActor
struct QuickAccessGridChecks {
    @Test func resizingReflowsTheSameCellsWithoutClippingOrOverlapping() async throws {
        var cells: [Int: NSView] = [:]
        let content = QuickAccessGridLayout {
            ForEach(0..<8) { index in
                GridCellProbe(height: index == 0 ? 78 : 56) { cells[index] = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 500), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        var originals: [Int: NSView] = [:]
        for (width, columns) in [(1400.0, 4), (900.0, 3), (640.0, 2), (1400.0, 4)] {
            window.setContentSize(NSSize(width: width, height: 500))
            try await requireEventually {
                host.layoutSubtreeIfNeeded()
                return cells.count == 8
                    && Set(cells.values.map { $0.convert($0.bounds, to: host).minX }).count == columns
            }
            if originals.isEmpty { originals = cells }
            let frames = try (0..<8).map { index in
                let cell = try #require(cells[index])
                #expect(cell === originals[index])
                return cell.convert(cell.bounds, to: host)
            }
            #expect(frames[0].height == 78)
            #expect(Set(frames.map(\.minY)).count == (8 + columns - 1) / columns)
            for (index, frame) in frames.enumerated() {
                #expect(frame.minX >= 0 && frame.maxX <= width)
                #expect(frame.height >= 56)
                for other in frames.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
            }
        }
    }
}

/// Native probes exercise SwiftUI's actual proposal/placement path and retain view identity.
@MainActor
private struct GridCellProbe: NSViewRepresentable {
    let height: CGFloat
    let capture: (NSView) -> Void

    func makeNSView(context: Context) -> GridCellView {
        let view = GridCellView(height: height)
        capture(view)
        return view
    }

    func updateNSView(_ nsView: GridCellView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GridCellView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220, height: height)
    }
}

@MainActor
private final class GridCellView: NSView {
    let height: CGFloat
    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: height) }
}
