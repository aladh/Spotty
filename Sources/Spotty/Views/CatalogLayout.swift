import SwiftUI

enum CatalogLayout {
    static let contentPadding: CGFloat = 28
    static let headerThreshold: CGFloat = 640
    static let headerCompactArtwork: CGFloat = 152
    static let headerMinimumArtwork: CGFloat = 184
    static let headerMediumArtwork: CGFloat = 208
    static let headerMaximumArtwork: CGFloat = 236
    static let playlistRowContentHeight: CGFloat = 40
    static let cardArtwork: CGFloat = 160
    static let cardPadding: CGFloat = 8
    static let cardCornerRadius: CGFloat = 11
    static let gridMinimumWidth: CGFloat = cardArtwork + (cardPadding * 2)
    static let gridMaximumWidth: CGFloat = 208
    static let gridSpacing: CGFloat = 16
}

enum MediaGridLayout {
    static var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: CatalogLayout.gridMinimumWidth, maximum: CatalogLayout.gridMaximumWidth),
                spacing: CatalogLayout.gridSpacing
            )
        ]
    }
}
