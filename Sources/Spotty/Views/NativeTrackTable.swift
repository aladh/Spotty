import AppKit
import SpottyDomain
import SwiftUI

/// Owns the table and scroll view directly. SwiftUI provides values and leaf content; native
/// row indexes are translated to occurrence IDs before crossing back into the presentation.
struct NativeTrackTable: NSViewRepresentable {
    @Environment(\.artworkAccess) private var artworkAccess
    let rows: [TrackTableRow]
    let variant: TrackTableVariant
    let playback: CatalogPlaybackAccess
    let metadata: CatalogMetadataRepository
    let searchQuery: String
    @Binding var selection: Set<CatalogTrack.ID>
    @Binding var sortOrder: [KeyPathComparator<TrackTableRow>]
    @Binding var scrollOffset: CGFloat
    let playlistActions: TrackPlaylistActions?
    let onSelect: ((CatalogItem) -> Void)?
    let playlistHeader: AnyView?
    let compactPlaylistHeader: AnyView?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NativeTrackTableContainer {
        let view = NativeTrackTableContainer(variant: variant)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: NativeTrackTableContainer, context: Context) {
        context.coordinator.update(self, in: view)
    }

    static func dismantleNSView(_ view: NativeTrackTableContainer, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var content: NativeTrackTable
        private var displayedRows: [TrackTableRow] = []
        private var applyingUpdate = false
        private weak var container: NativeTrackTableContainer?

        init(_ content: NativeTrackTable) { self.content = content }

        func attach(to container: NativeTrackTableContainer) {
            self.container = container
            container.table.dataSource = self
            container.table.delegate = self
            container.table.target = self
            container.table.doubleAction = #selector(activateClickedRow)
            container.table.primaryAction = { [weak self] in self?.activateSelection() }
            container.table.deleteAction = { [weak self] in self?.removeSelection() ?? false }
            container.table.contextMenu = { [weak self] in self?.selectionMenu() }
            container.onScroll = { [weak self] offset in
                guard let self, !applyingUpdate, abs(content.scrollOffset - offset) > 0.5 else { return }
                content.scrollOffset = offset
            }
        }

        func detach(from container: NativeTrackTableContainer) {
            container.onScroll = nil
            container.table.dataSource = nil
            container.table.delegate = nil
            container.table.target = nil
            container.table.primaryAction = nil
            container.table.deleteAction = nil
            container.table.contextMenu = nil
            self.container = nil
        }

        func update(_ next: NativeTrackTable, in container: NativeTrackTableContainer) {
            applyingUpdate = true
            defer { applyingUpdate = false }
            let oldRows = displayedRows
            content = next
            displayedRows = next.rows
            container.updateHeaders(
                hero: next.playlistHeader.map {
                    AnyView($0.environment(\.artworkAccess, next.artworkAccess).id(next.artworkAccess.accountEpoch))
                },
                compact: next.compactPlaylistHeader.map {
                    AnyView($0.environment(\.artworkAccess, next.artworkAccess).id(next.artworkAccess.accountEpoch))
                },
                sortOrder: next.sortOrder,
                sort: { [weak self] column in self?.sort(column) }
            )
            // Metadata/playing changes are observed by hosted leaves. Reconfigure only changed
            // occurrences; sorting, filtering or membership changes require a structural reload.
            if oldRows.map(\.id) != next.rows.map(\.id) || container.table.numberOfRows != next.rows.count {
                container.table.reloadData()
            } else {
                let changed = IndexSet(next.rows.indices.filter { next.rows[$0] != oldRows[$0] })
                if !changed.isEmpty {
                    container.table.reloadData(
                        forRowIndexes: changed,
                        columnIndexes: IndexSet(integersIn: 0..<container.table.numberOfColumns)
                    )
                }
            }
            let desired = IndexSet(next.rows.indices.filter { next.selection.contains(next.rows[$0].id) })
            if container.table.selectedRowIndexes != desired {
                container.table.selectRowIndexes(desired, byExtendingSelection: false)
            }
            container.rowCount = next.rows.count
            container.layoutSubtreeIfNeeded()
            container.restoreScrollOffset(next.scrollOffset)
            refreshVisibleSelection(in: container.table)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayedRows.indices.contains(row), let tableColumn,
                let column = NativeTrackColumn(rawValue: tableColumn.identifier.rawValue)
            else { return nil }
            let cell =
                tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NativeTrackHostingCell
                ?? NativeTrackHostingCell()
            cell.identifier = tableColumn.identifier
            configure(cell, row: row, column: column)
            return cell
        }

        private func configure(_ cell: NativeTrackHostingCell, row: Int, column: NativeTrackColumn) {
            cell.host.rootView = AnyView(
                NativeTrackCell(
                    row: displayedRows[row], column: column, position: row + 1, total: displayedRows.count,
                    variant: content.variant, isSelected: content.selection.contains(displayedRows[row].id),
                    playback: content.playback, metadata: content.metadata, searchQuery: content.searchQuery,
                    onSelect: content.onSelect
                )
                .environment(\.artworkAccess, content.artworkAccess)
                .id("\(content.artworkAccess.accountEpoch):\(displayedRows[row].id)")
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column == .index ? .trailing : .leading)
            )
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            NativeTrackRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingUpdate, let table = notification.object as? NSTableView else { return }
            content.selection = Set(
                table.selectedRowIndexes.compactMap { index in
                    displayedRows.indices.contains(index) ? displayedRows[index].id : nil
                })
            refreshVisibleSelection(in: table)
        }

        private func refreshVisibleSelection(in table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<min(NSMaxRange(visible), displayedRows.count) {
                for (index, column) in NativeTrackColumn.columns(for: content.variant).enumerated() {
                    if let cell = table.view(atColumn: index, row: row, makeIfNecessary: false)
                        as? NativeTrackHostingCell
                    {
                        configure(cell, row: row, column: column)
                    }
                }
            }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let column = NativeTrackColumn(rawValue: tableColumn.identifier.rawValue) else { return }
            sort(column)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !applyingUpdate else { return }
            container?.didResizeColumns()
        }

        private func sort(_ column: NativeTrackColumn) {
            guard var comparator = column.comparator else { return }
            if let current = content.sortOrder.first, current.keyPath == comparator.keyPath {
                comparator.order = current.order == .forward ? .reverse : .forward
            }
            content.sortOrder = [comparator]
        }

        private var selectedTracks: [CatalogTrack] {
            PlaylistMutationSelection.orderedTracks(selectedIDs: content.selection, in: displayedRows.map(\.track))
        }

        @objc private func activateClickedRow() {
            guard let table = container?.table, displayedRows.indices.contains(table.clickedRow) else { return }
            activateSelection()
        }

        private func activateSelection() {
            guard content.playback.canStartPlayback, selectedTracks.count == 1,
                let track = selectedTracks.first
            else { return }
            content.playback.playTrack(track)
        }

        private func removeSelection() -> Bool {
            guard let actions = content.playlistActions, actions.canRemoveOccurrences else { return false }
            let ids = PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks)
            guard !ids.isEmpty else { return false }
            actions.removeOccurrences(selectedTracks.map(\.id))
            return true
        }

        private func selectionMenu() -> NSMenu? {
            let tracks = selectedTracks
            guard !tracks.isEmpty else { return nil }
            let menu = NSMenu()
            if tracks.count == 1, let track = tracks.first {
                menu.addAction("Play", systemImage: "play.fill", enabled: content.playback.canStartPlayback) {
                    [playback = content.playback] in
                    playback.playTrack(track)
                }
            }
            menu.addAction(
                "Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward",
                enabled: content.playback.canStartPlayback
            ) {
                [playback = content.playback] in
                playback.addToQueue(QueueMutationSelection.addURIs(from: tracks))
            }
            if let actions = content.playlistActions {
                let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: item.title)
                if actions.editablePlaylists.isEmpty {
                    submenu.addAction("No Editable Playlists", enabled: false) {}
                } else {
                    for playlist in actions.editablePlaylists {
                        submenu.addAction(playlist.title) { actions.addToPlaylist(playlist, tracks) }
                    }
                }
                item.submenu = submenu
                menu.addItem(item)
                if actions.canRemoveOccurrences {
                    let ids = PlaylistMutationSelection.occurrenceIDsForRemoval(from: tracks)
                    menu.addItem(.separator())
                    menu.addAction("Remove from Playlist", enabled: !ids.isEmpty) {
                        actions.removeOccurrences(tracks.map(\.id))
                    }
                }
            }
            return menu
        }
    }
}

@MainActor
final class NativeTrackHostingCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class NativeTrackMenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func perform(_ sender: NSMenuItem) { action() }
}

extension NSMenu {
    @MainActor
    func addAction(
        _ title: String, systemImage: String? = nil, enabled: Bool = true, action: @escaping @MainActor () -> Void
    ) {
        autoenablesItems = false
        let target = NativeTrackMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(NativeTrackMenuAction.perform(_:)), keyEquivalent: "")
        if let systemImage { item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        addItem(item)
    }
}
