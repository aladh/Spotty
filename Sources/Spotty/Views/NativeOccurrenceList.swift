import AppKit
import SwiftUI

/// A stable occurrence plus a SwiftUI leaf. Section headings and other auxiliary content remain
/// explicit nonselectable rows instead of borrowing the identity of a playable occurrence.
struct NativeOccurrenceListRow {
    let id: String
    let height: CGFloat
    var isSelectable = true
    var drawsHover = false
    let content: AnyView
}

/// Kept by presentation across navigation; native scrolling never invalidates SwiftUI.
@MainActor
final class NativeListScrollState {
    var offset: CGFloat = 0
}

/// One owned native list for the library and playback rail. It shares the native keyboard and
/// selection implementation with track tables while keeping each surface's Spotify leaf styling.
struct NativeOccurrenceList: NSViewRepresentable {
    @Environment(\.artworkAccess) private var artworkAccess
    let rows: [NativeOccurrenceListRow]
    @Binding var selection: Set<String>
    var allowsMultipleSelection = true
    var drawsSelection = true
    var preservesVisibleAnchor = false
    let accessibilityLabel: String
    var scrollState: NativeListScrollState?
    var primaryAction: ((Set<String>) -> Void)?
    var deleteAction: ((Set<String>) -> Bool)?
    var contextMenu: ((Set<String>) -> NSMenu?)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NativeOccurrenceScrollView {
        let scroll = NativeOccurrenceScrollView()
        context.coordinator.attach(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NativeOccurrenceScrollView, context: Context) {
        context.coordinator.update(self, in: scroll)
    }

    static func dismantleNSView(_ scroll: NativeOccurrenceScrollView, coordinator: Coordinator) {
        coordinator.detach(from: scroll)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var content: NativeOccurrenceList
        private var applyingUpdate = false
        private var hasAppliedContent = false
        private weak var scroll: NativeOccurrenceScrollView?

        init(_ content: NativeOccurrenceList) { self.content = content }

        func attach(to scroll: NativeOccurrenceScrollView) {
            self.scroll = scroll
            scroll.onScroll = { [weak self] offset in
                guard let self, !applyingUpdate else { return }
                content.scrollState?.offset = offset
            }
            scroll.table.delegate = self
            scroll.table.dataSource = self
            scroll.table.target = self
            scroll.table.canSelectRow = { [weak self] row in
                guard let self, content.rows.indices.contains(row) else { return false }
                return content.rows[row].isSelectable
            }
            scroll.table.doubleAction = #selector(activateClickedRow)
            scroll.table.primaryAction = { [weak self] in self?.activateSelection() }
            scroll.table.focusSelectedControl = { [weak self] in self?.focusSelectedControl() ?? false }
            scroll.table.deleteAction = { [weak self] in
                guard let self else { return false }
                return content.deleteAction?(selectedIDs) ?? false
            }
            scroll.table.contextMenu = { [weak self] in
                guard let self else { return nil }
                return content.contextMenu?(selectedIDs)
            }
        }

        func detach(from scroll: NativeOccurrenceScrollView) {
            scroll.onScroll = nil
            scroll.table.delegate = nil
            scroll.table.dataSource = nil
            scroll.table.target = nil
            scroll.table.canSelectRow = nil
            scroll.table.primaryAction = nil
            scroll.table.focusSelectedControl = nil
            scroll.table.deleteAction = nil
            scroll.table.contextMenu = nil
            self.scroll = nil
        }

        func update(_ next: NativeOccurrenceList, in scroll: NativeOccurrenceScrollView) {
            applyingUpdate = true
            defer { applyingUpdate = false }
            let offset = next.scrollState?.offset ?? scroll.contentView.bounds.minY
            let previousRows = content.rows
            let structureChanged =
                content.rows.map(\.id) != next.rows.map(\.id)
                || content.rows.map(\.height) != next.rows.map(\.height)
            var anchor: (id: String, distance: CGFloat)?
            if next.preservesVisibleAnchor, hasAppliedContent, structureChanged,
                next.scrollState === content.scrollState,
                abs(offset - scroll.contentView.bounds.minY) < 0.5
            {
                let row = scroll.table.row(at: NSPoint(x: 0, y: offset))
                if content.rows.indices.contains(row) {
                    anchor = (content.rows[row].id, offset - scroll.table.rect(ofRow: row).minY)
                }
            }
            scroll.table.allowsMultipleSelection = next.allowsMultipleSelection
            scroll.table.selectionHighlightStyle = next.drawsSelection ? .regular : .none
            scroll.table.setAccessibilityLabel(next.accessibilityLabel)
            scroll.table.contextMenu =
                next.contextMenu == nil
                ? nil
                : { [weak self] in
                    guard let self else { return nil }
                    return content.contextMenu?(selectedIDs)
                }
            if !hasAppliedContent || scroll.table.numberOfRows != previousRows.count {
                content = next
                scroll.table.reloadData()
            } else if structureChanged {
                updateRows(to: next, in: scroll.table)
            } else {
                content = next
            }
            hasAppliedContent = true
            let desired = IndexSet(
                next.rows.indices.filter {
                    next.rows[$0].isSelectable && next.selection.contains(next.rows[$0].id)
                })
            if scroll.table.selectedRowIndexes != desired {
                scroll.table.selectRowIndexes(desired, byExtendingSelection: false)
            }
            refreshVisibleRows()
            scroll.layoutSubtreeIfNeeded()
            let maximum = max(0, scroll.table.bounds.height - scroll.contentSize.height)
            let requested =
                anchor.flatMap { anchor in
                    next.rows.firstIndex { $0.id == anchor.id }.map {
                        scroll.table.rect(ofRow: $0).minY + anchor.distance
                    }
                } ?? offset
            let restored = min(maximum, max(0, requested))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: restored))
            scroll.reflectScrolledClipView(scroll.contentView)
            next.scrollState?.offset = restored
        }

        /// Keep unaffected library cells attached so folder controls retain keyboard focus.
        /// Mixed-height lists retain full reloads: incremental AppKit insertion can leave stale
        /// offscreen row origins. Comparing shared ends stays linear even for large reorders.
        private func updateRows(to next: NativeOccurrenceList, in table: NSTableView) {
            let previous = content.rows
            let rows = next.rows
            guard let height = previous.first?.height,
                previous.allSatisfy({ $0.height == height }), rows.allSatisfy({ $0.height == height })
            else {
                content = next
                table.reloadData()
                return
            }
            let sharedLimit = min(previous.count, rows.count)
            var prefix = 0
            while prefix < sharedLimit, previous[prefix].id == rows[prefix].id { prefix += 1 }
            var suffix = 0
            while suffix < sharedLimit - prefix,
                previous[previous.count - suffix - 1].id == rows[rows.count - suffix - 1].id
            { suffix += 1 }
            guard prefix + suffix > 0 else {
                content = next
                table.reloadData()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                table.beginUpdates()
                content = next
                table.removeRows(at: IndexSet(integersIn: prefix..<(previous.count - suffix)), withAnimation: [])
                table.insertRows(at: IndexSet(integersIn: prefix..<(rows.count - suffix)), withAnimation: [])
                table.endUpdates()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { content.rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { content.rows[row].height }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { content.rows[row].isSelectable }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NativeTrackRowView()
            view.drawsHover = content.rows[row].drawsHover
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard content.rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("occurrence")
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? NativeTrackHostingCell
                ?? NativeTrackHostingCell()
            cell.identifier = identifier
            configure(cell, at: row)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingUpdate else { return }
            content.selection = selectedIDs
            refreshVisibleRows()
        }

        private var selectedIDs: Set<String> {
            guard let table = scroll?.table else { return [] }
            return Set(
                table.selectedRowIndexes.compactMap { row in
                    content.rows.indices.contains(row) && content.rows[row].isSelectable ? content.rows[row].id : nil
                })
        }

        private func refreshVisibleRows() {
            guard let table = scroll?.table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<min(NSMaxRange(visible), content.rows.count) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeTrackHostingCell {
                    configure(cell, at: row)
                }
            }
        }

        private func configure(_ cell: NativeTrackHostingCell, at row: Int) {
            let contentID = "\(content.artworkAccess.accountEpoch):\(content.rows[row].id)"
            cell.prepareFocusTarget(contentID: contentID, table: scroll?.table)
            cell.host.rootView = AnyView(
                content.rows[row].content
                    .environment(\.artworkAccess, content.artworkAccess)
                    .environment(\.nativeRowFocusTarget, cell.focusTarget)
                    .id(contentID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }

        @objc private func activateClickedRow() {
            guard let table = scroll?.table, content.rows.indices.contains(table.clickedRow),
                content.rows[table.clickedRow].isSelectable
            else { return }
            activateSelection()
        }

        private func activateSelection() { content.primaryAction?(selectedIDs) }

        private func focusSelectedControl() -> Bool {
            guard let table = scroll?.table, table.selectedRowIndexes.count == 1,
                content.rows.indices.contains(table.selectedRow), content.rows[table.selectedRow].isSelectable,
                let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false)
                    as? NativeTrackHostingCell
            else { return false }
            return cell.focusTarget.focus()
        }
    }
}

@MainActor
final class NativeOccurrenceScrollView: NSScrollView {
    let table = NativeTrackTableView()
    var onScroll: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.minWidth = 0
        column.maxWidth = 10_000
        table.addTableColumn(column)
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView
        )
    }

    required init?(coder: NSCoder) { nil }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled(_ notification: Notification) { onScroll?(contentView.bounds.minY) }

    override func layout() {
        super.layout()
        let width = contentSize.width
        if table.frame.width != width { table.frame.size.width = width }
        if table.tableColumns.first?.width != width { table.tableColumns.first?.width = width }
    }
}
