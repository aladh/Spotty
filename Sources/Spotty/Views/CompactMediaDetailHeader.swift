import SwiftUI

/// Retains the collection identity and primary action while its artwork hero scrolls away.
struct CompactMediaDetailHeader: View {
    let title: String
    let action: CatalogPlaybackAction

    var body: some View {
        HStack(spacing: 8) {
            CatalogPlaybackButton(action: action) { showsPause in
                TransportSymbol(kind: showsPause ? .pause : .play)
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .frame(width: 48, height: 48)
                    .background(SpottyPalette.mediaGreen, in: Circle())
            }
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(SpottyPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(SpottyPalette.selectedControl)
    }
}
