import SwiftUI

/// At most eight shortcuts: measure synchronously and keep the same controls while resizing.
struct QuickAccessGridLayout: Layout {
    private let spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        metrics(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            let column = index % grid.columns
            let row = index / grid.columns
            view.place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.columnWidth + spacing), y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: grid.columnWidth, height: grid.rowHeights[row]))
            if column == grid.columns - 1 { y += grid.rowHeights[row] + spacing }
        }
    }

    private func metrics(width proposedWidth: CGFloat?, subviews: Subviews) -> (
        size: CGSize, columnWidth: CGFloat, columns: Int, rowHeights: [CGFloat]
    ) {
        guard !subviews.isEmpty else { return (.zero, 0, 1, []) }
        let idealColumns = min(4, subviews.count)
        let idealWidth = CGFloat(idealColumns) * 220 + CGFloat(idealColumns - 1) * spacing
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        let columns = max(1, Int(min(4, (width + spacing) / (220 + spacing))))
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var rowHeights: [CGFloat] = []
        for (index, view) in subviews.enumerated() {
            let height = view.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            if index % columns == 0 {
                rowHeights.append(height)
            } else {
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], height)
            }
        }
        let height = rowHeights.reduce(0, +) + CGFloat(rowHeights.count - 1) * spacing
        return (CGSize(width: width, height: height), columnWidth, columns, rowHeights)
    }
}
