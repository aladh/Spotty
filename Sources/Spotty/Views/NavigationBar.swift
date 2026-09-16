import SwiftUI

struct NavigationBar: View {
    @Binding var searchText: String
    let isHome: Bool
    let isSearch: Bool
    let goHome: () -> Void
    let showSearch: () -> Void
    @State private var searchField = NavigationSearchField.Controller()
    @FocusState private var homeIsFocused: Bool
    @State private var homeIsHovered = false
    @State private var searchIsHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: goHome) {
                NavigationSymbol(kind: isHome ? .homeFilled : .home)
                    .fill(style: FillStyle(eoFill: true))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(
                        isHome || homeIsHovered ? SpottyPalette.textPrimary : SpottyPalette.textSecondary
                    )
                    .frame(width: 48, height: 48)
                    .background(
                        homeIsHovered ? SpottyPalette.elevatedHighlight : SpottyPalette.navigationControl, in: Circle()
                    )
                    .scaleEffect(homeIsHovered ? 1.04 : 1)
            }
            .animation(.easeOut(duration: 0.15), value: homeIsHovered)
            .onHover { homeIsHovered = $0 }
            .accessibilityLabel("Home")
            .help("Home")
            .focusable()
            .focused($homeIsFocused)
            HStack(spacing: 12) {
                Button {
                    searchField.focus()
                } label: {
                    NavigationSymbol(kind: .search)
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(
                            searchField.isFocused || searchIsHovered
                                ? SpottyPalette.textPrimary : SpottyPalette.textSecondary
                        )
                }
                .accessibilityLabel("Search")
                .keyboardShortcut("l", modifiers: .command)
                NavigationSearchField(text: $searchText, controller: searchField, onActivate: showSearch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { searchIsHovered = $0 }
            .padding(.horizontal, 12)
            .frame(maxWidth: 474)
            .frame(height: 48)
            .background {
                Capsule()
                    .fill(searchIsHovered ? SpottyPalette.elevatedHighlight : SpottyPalette.navigationControl)
                    .onTapGesture { searchField.focus() }
            }
            .overlay {
                Capsule().strokeBorder(searchField.isFocused ? SpottyPalette.textPrimary : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 18))
        .frame(width: 530)
        .padding(.vertical, 8)
        .onChange(of: searchText) {
            if !searchText.isEmpty { showSearch() }
        }
        .onChange(of: isSearch) {
            if !isSearch { searchField.blur() }
        }
        .defaultFocus($homeIsFocused, true)
    }
}

private struct NavigationSymbol: Shape {
    enum Kind { case home, homeFilled, search }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .home, .homeFilled:
            path.addLines([
                CGPoint(x: 12, y: 1), CGPoint(x: 2, y: 8.5), CGPoint(x: 2, y: 22),
                CGPoint(x: 9, y: 22), CGPoint(x: 9, y: 15),
                CGPoint(x: 15, y: 15), CGPoint(x: 15, y: 22),
                CGPoint(x: 22, y: 22), CGPoint(x: 22, y: 8.5),
            ])
            path.closeSubpath()
            if kind == .home {
                path.addLines([
                    CGPoint(x: 12, y: 3.5), CGPoint(x: 4, y: 9.5), CGPoint(x: 4, y: 20),
                    CGPoint(x: 7, y: 20), CGPoint(x: 7, y: 13),
                    CGPoint(x: 17, y: 13), CGPoint(x: 17, y: 20),
                    CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 9.5),
                ])
                path.closeSubpath()
            }
        case .search:
            path.addEllipse(in: CGRect(x: 1, y: 1, width: 19, height: 19))
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 15, height: 15))
            path.addLines([
                CGPoint(x: 17.92, y: 16.5), CGPoint(x: 23, y: 21.58),
                CGPoint(x: 21.58, y: 23), CGPoint(x: 16.5, y: 17.92),
            ])
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
