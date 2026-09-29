import AppKit
import SpottyDomain
import SwiftUI

/// Plain metadata needs native text layout, not an independently hosted SwiftUI graph per cell.
@MainActor
final class NativeTrackTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(SpottyPalette.dataText)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setAccessibilityRole(.staticText)
        textField = label
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        track: CatalogTrack, column: NativeTrackColumn, variant: TrackTableVariant,
        playCount: Int64?, isPlayable: Bool
    ) {
        precondition(column.isPlainText)
        switch column {
        case .dateAdded: label.stringValue = formatPlaylistDateAdded(track.addedAt)
        case .duration:
            label.stringValue =
                variant == .playlist || variant == .search
                ? formatCatalogDuration(track.duration) : formatDuration(track.duration)
        case .playCount: label.stringValue = playCount?.formatted() ?? ""
        default: break
        }
        label.font =
            column == .duration ? .monospacedDigitSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 14)
        label.alignment = column == .duration && variant != .catalog ? .center : .left
        label.alphaValue = isPlayable ? 1 : 0.45
        label.setAccessibilityLabel(column == .playCount ? playCount.map { "\($0.formatted()) plays" } : nil)
        label.setAccessibilityElement(!label.stringValue.isEmpty)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        // Borderless NSTextField adds two points on each side when rendering text.
        // Compensate so the visible text retains the hosted cell's eight-point inset.
        label.frame = NSRect(
            x: 6, y: (bounds.height - height) / 2,
            width: max(0, bounds.width - 12), height: height)
    }
}
