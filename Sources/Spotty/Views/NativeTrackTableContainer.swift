import AppKit
import SpottyDomain
import SwiftUI

/// The document, playlist hero, column headers and table share one owned scroll coordinate space.
/// The compact hero is an overlay of that container, independent of SwiftUI's List implementation.
@MainActor
final class NativeTrackTableContainer: NSView {
    let scrollView = NSScrollView()
    let table = NativeTrackTableView()
    private let document = NativeTrackDocumentView()
    private let hero = NSHostingView(rootView: AnyView(EmptyView()))
    private let columnHeader = NSHostingView(rootView: AnyView(EmptyView()))
    private let catalogHeader = NSTableHeaderView()
    private let compactHeader = NSHostingView(rootView: AnyView(EmptyView()))
    private let variant: TrackTableVariant
    private var heroContent: AnyView?
    private var compactContent: AnyView?
    private var order: [KeyPathComparator<TrackTableRow>] = []
    private var sort: ((NativeTrackColumn) -> Void)?
    private var heroHeight: CGFloat = 0
    private var catalogColumnWidths: [CGFloat]?
    private var configuringColumns = false
    var rowCount = 0 { didSet { if rowCount != oldValue { needsLayout = true } } }
    var onScroll: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }

    init(variant: TrackTableVariant) {
        self.variant = variant
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = document
        table.revealRow = { [weak self] in self?.reveal(row: $0) }
        scrollView.setAccessibilityLabel("Tracks")
        table.setAccessibilityLabel("Tracks")
        table.style = .plain
        table.backgroundColor = .clear
        table.headerView = nil
        table.intercellSpacing = .zero
        table.rowHeight = variant == .playlist ? 56 : 32
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = variant == .catalog
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in NativeTrackColumn.columns(for: variant) {
            let native = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            native.title = column.title
            native.resizingMask = variant == .catalog ? .userResizingMask : []
            if variant == .catalog {
                let cell = NativeTrackHeaderCell(textCell: column.title)
                native.headerCell = cell
                switch column {
                case .title: native.minWidth = 152; native.maxWidth = 264
                case .artist: native.minWidth = 96; native.maxWidth = 160
                case .album: native.minWidth = 96; native.maxWidth = 170
                default: native.minWidth = 38; native.maxWidth = 96
                }
            }
            table.addTableColumn(native)
        }
        addSubview(scrollView)
        document.addSubview(hero)
        if variant == .catalog {
            table.headerView = catalogHeader
            document.addSubview(catalogHeader)
        } else {
            document.addSubview(columnHeader)
        }
        document.addSubview(table)
        addSubview(compactHeader)
        compactHeader.isHidden = true
        hero.sizingOptions = [.intrinsicContentSize]
        compactHeader.sizingOptions = [.intrinsicContentSize]
        columnHeader.sizingOptions = []
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    func updateHeaders(
        hero: AnyView?, compact: AnyView?, sortOrder: [KeyPathComparator<TrackTableRow>],
        sort: @escaping (NativeTrackColumn) -> Void
    ) {
        heroContent = hero
        compactContent = compact
        order = sortOrder
        self.sort = sort
        for column in table.tableColumns {
            guard let cell = column.headerCell as? NativeTrackHeaderCell,
                let kind = NativeTrackColumn(rawValue: column.identifier.rawValue), let comparator = kind.comparator
            else { continue }
            cell.order = sortOrder.first.flatMap { $0.keyPath == comparator.keyPath ? $0.order : nil }
            cell.setAccessibilityValue(
                cell.order.map { $0 == .forward ? "Sorted ascending" : "Sorted descending" } ?? "")
        }
        catalogHeader.needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let viewportWidth = scrollView.contentSize.width
        let inset: CGFloat = variant == .playlist ? 24 : 8
        let indexWidth = max(24, CGFloat(String(max(1, rowCount)).count) * 9)
        let minimumWidth: CGFloat = variant == .playlist ? 576 + indexWidth : 534
        let customWidth = catalogColumnWidths?.reduce(0, +) ?? 0
        let proposedWidth = max(minimumWidth, viewportWidth - inset * 2, customWidth)
        configuringColumns = true
        for (column, width) in zip(table.tableColumns, columnWidths(tableWidth: proposedWidth)) {
            column.width = width
        }
        configuringColumns = false
        // AppKit clamps each column to its own range. Reserve its effective width so the
        // rightmost columns remain reachable at narrow window sizes.
        let widths = table.tableColumns.map(\.width)
        let tableWidth = max(proposedWidth, widths.reduce(0, +))
        let documentWidth = max(viewportWidth, tableWidth + inset * 2)
        if let heroContent {
            hero.rootView = AnyView(heroContent.frame(width: documentWidth))
            hero.frame.size.width = documentWidth
            heroHeight = max(0, hero.fittingSize.height)
        } else {
            heroHeight = 0
        }
        hero.frame = NSRect(x: 0, y: 0, width: documentWidth, height: heroHeight)
        let headers = NativeTrackColumnHeaders(
            columns: NativeTrackColumn.columns(for: variant), widths: widths,
            sortOrder: order, sort: { [weak self] in self?.sort?($0) }
        )
        columnHeader.rootView = AnyView(headers)
        columnHeader.frame = NSRect(x: inset, y: heroHeight, width: tableWidth, height: 36)
        catalogHeader.frame = columnHeader.frame
        let tableY = heroHeight + 36
        let tableHeight = max(CGFloat(rowCount) * table.rowHeight, scrollView.contentSize.height - tableY)
        table.frame = NSRect(x: inset, y: tableY, width: tableWidth, height: tableHeight)
        document.frame = NSRect(x: 0, y: 0, width: documentWidth, height: tableY + tableHeight)
        if let compactContent {
            compactHeader.rootView = AnyView(
                VStack(spacing: 0) {
                    compactContent
                    headers.padding(.horizontal, inset)
                }
                .frame(width: documentWidth)
                .background(SpottyPalette.catalogCanvas)
            )
            compactHeader.frame.size.width = documentWidth
            compactHeader.frame = NSRect(
                x: -scrollView.contentView.bounds.minX, y: 0,
                width: documentWidth, height: compactHeader.fittingSize.height
            )
        }
        updateCompactHeader()
    }

    func restoreScrollOffset(_ offset: CGFloat) {
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let desired = min(maximum, max(0, offset))
        guard abs(clip.bounds.minY - desired) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: desired))
        scrollView.reflectScrolledClipView(clip)
        updateCompactHeader()
    }

    private func reveal(row: Int) {
        guard row >= 0 && row < table.numberOfRows else { return }
        let rowRect = table.convert(table.rect(ofRow: row), to: document)
        let clip = scrollView.contentView.bounds
        let coveredHeight = compactHeader.isHidden ? 0 : compactHeader.frame.height
        if rowRect.minY < clip.minY + coveredHeight {
            restoreScrollOffset(rowRect.minY - coveredHeight)
        } else if rowRect.maxY > clip.maxY {
            restoreScrollOffset(rowRect.maxY - clip.height)
        }
    }

    @objc private func scrolled(_ notification: Notification) {
        updateCompactHeader()
        onScroll?(scrollView.contentView.bounds.minY)
    }

    private func updateCompactHeader() {
        compactHeader.isHidden =
            compactContent == nil || heroHeight <= 64
            || scrollView.contentView.bounds.minY < heroHeight - 64
        compactHeader.frame.origin.x = -scrollView.contentView.bounds.minX
    }

    func didResizeColumns() {
        if variant == .catalog && !configuringColumns {
            catalogColumnWidths = table.tableColumns.map(\.width)
            needsLayout = true
        }
    }

    private func columnWidths(tableWidth: CGFloat) -> [CGFloat] {
        if variant == .playlist {
            let index = max(24, CGFloat(String(max(1, rowCount)).count) * 9)
            let flexible = max(400, tableWidth - 176 - index)
            return [index + 24, flexible / 2 + 16, flexible / 4 + 16, flexible / 4 + 16, 104]
        }
        if let catalogColumnWidths { return catalogColumnWidths }
        let flexible = max(344, tableWidth - 190)
        return [flexible * 0.46, flexible * 0.26, flexible * 0.28, 64, 44, 38, 44]
    }
}

@MainActor
private final class NativeTrackDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct NativeTrackColumnHeaders: View {
    let columns: [NativeTrackColumn]
    let widths: [CGFloat]
    let sortOrder: [KeyPathComparator<TrackTableRow>]
    let sort: (NativeTrackColumn) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(columns, widths)), id: \.0) { column, width in
                Button {
                    sort(column)
                } label: {
                    HStack(spacing: 8) {
                        if column == .duration {
                            Image(systemName: "clock").font(.system(size: 16))
                        } else {
                            Text(column.title)
                        }
                        if let comparator = column.comparator, let active = sortOrder.first,
                            active.keyPath == comparator.keyPath
                        {
                            Image(
                                systemName: active.order == .forward
                                    ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
                            )
                            .font(.system(size: 8)).foregroundStyle(SpottyPalette.mediaGreen)
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        alignment: column == .index ? .trailing : (column == .duration ? .center : .leading)
                    )
                    .padding(.horizontal, 8)
                    .frame(width: width, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(column.comparator == nil)
                .accessibilityLabel(
                    column.comparator == nil
                        ? column.title : "Sort by \(column == .duration ? "duration" : column.title)"
                )
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(SpottyPalette.dataText)
        .overlay(alignment: .bottom) { Color.white.opacity(0.1).frame(height: 1) }
    }

    private func sortDescription(for column: NativeTrackColumn) -> String {
        guard let comparator = column.comparator, let active = sortOrder.first,
            comparator.keyPath == active.keyPath
        else { return "" }
        return active.order == .forward ? "Sorted ascending" : "Sorted descending"
    }
}

@MainActor
final class NativeTrackTableView: NSTableView {
    var primaryAction: (() -> Void)?
    var deleteAction: (() -> Bool)?
    var contextMenu: (() -> NSMenu?)?
    var revealRow: ((Int) -> Void)?
    var canSelectRow: ((Int) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let unmodified = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if unmodified && (event.keyCode == 36 || event.keyCode == 76) {
            if !event.isARepeat { primaryAction?() }
        } else if unmodified && (event.keyCode == 51 || event.keyCode == 117) {
            if event.isARepeat { return }
            if deleteAction?() != true { super.keyDown(with: event) }
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollRowToVisible(_ row: Int) {
        super.scrollRowToVisible(row)
        revealRow?(row)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let contextMenu else { return super.menu(for: event) }
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0, canSelectRow?(clicked) != false else { return nil }
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        window?.makeFirstResponder(self)
        return contextMenu()
    }
}

@MainActor
final class NativeTrackRowView: NSTableRowView {
    var drawsHover = true
    private var hoverTracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        if drawsHover && hovered && !isSelected { fill(alpha: 0.1) }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        fill(alpha: isEmphasized ? 0.2 : 0.13)
    }

    private func fill(alpha: CGFloat) {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

/// A native header keeps AppKit column resizing and keyboard accessibility while matching the
/// flat Spotify canvas. Sorting is performed by the shared occurrence projection.
@MainActor
private final class NativeTrackHeaderCell: NSTableHeaderCell {
    var order: SortOrder?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .paragraphStyle: paragraph,
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(SpottyPalette.dataText),
        ]
        let text = NSAttributedString(string: stringValue, attributes: attributes)
        let rect = NSRect(
            x: cellFrame.minX + 8, y: cellFrame.midY - 8,
            width: max(0, cellFrame.width - (order == nil ? 16 : 30)), height: 18)
        text.draw(in: rect)
        if let order {
            NSColor(SpottyPalette.mediaGreen).setFill()
            let x = min(cellFrame.maxX - 10, rect.minX + text.size().width + 12)
            let y = cellFrame.midY
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - 3, y: y + (order == .forward ? 2 : -2)))
            path.line(to: NSPoint(x: x + 3, y: y + (order == .forward ? 2 : -2)))
            path.line(to: NSPoint(x: x, y: y + (order == .forward ? -2 : 2)))
            path.close()
            path.fill()
        }
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
}
