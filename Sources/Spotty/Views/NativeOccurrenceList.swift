import AppKit
import SwiftUI

/// A stable occurrence plus a SwiftUI leaf. Section headings and other auxiliary content remain
/// explicit nonselectable rows instead of borrowing the identity of a playable occurrence.
struct NativeOccurrenceListRow {
    let id: String
    let height: CGFloat
    var isSelectable = true
    let content: AnyView
}

/// Kept by the presentation across rail-tab changes; native scrolling never invalidates SwiftUI.
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
            scroll.table.deleteAction = nil
            scroll.table.contextMenu = nil
            self.scroll = nil
        }

        func update(_ next: NativeOccurrenceList, in scroll: NativeOccurrenceScrollView) {
            applyingUpdate = true
            defer { applyingUpdate = false }
            let offset = next.scrollState?.offset ?? scroll.contentView.bounds.minY
            let structureChanged =
                content.rows.map(\.id) != next.rows.map(\.id)
                || content.rows.map(\.height) != next.rows.map(\.height)
            content = next
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
            if !hasAppliedContent || structureChanged || scroll.table.numberOfRows != next.rows.count {
                scroll.table.reloadData()
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
            let restored = min(maximum, max(0, offset))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: restored))
            scroll.reflectScrolledClipView(scroll.contentView)
            next.scrollState?.offset = restored
        }

        func numberOfRows(in tableView: NSTableView) -> Int { content.rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { content.rows[row].height }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { content.rows[row].isSelectable }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NativeTrackRowView()
            // These leaves already draw their own artwork/control hover treatment.
            view.drawsHover = false
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
            cell.host.rootView = AnyView(
                content.rows[row].content
                    .environment(\.artworkAccess, content.artworkAccess)
                    .id("\(content.artworkAccess.accountEpoch):\(content.rows[row].id)")
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
