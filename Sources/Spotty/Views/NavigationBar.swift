import SwiftUI

struct NavigationBar: View {
    @Binding var searchText: String
    let isHome: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    let goHome: () -> Void
    let showSearch: () -> Void
    private enum FocusTarget: Hashable {
        case home
        case search
    }
    @FocusState private var focusedControl: FocusTarget?
    @State private var homeIsHovered = false
    @State private var searchIsHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button("Go back", systemImage: "chevron.left", action: goBack)
                .disabled(!canGoBack)
                .keyboardShortcut("[", modifiers: .command)
            Button("Go forward", systemImage: "chevron.right", action: goForward)
                .disabled(!canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            Spacer(minLength: 16)
            Button(action: goHome) {
                NavigationSymbol(kind: isHome ? .homeFilled : .home)
                    .fill(style: FillStyle(eoFill: true))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isHome || homeIsHovered ? SpottyPalette.textPrimary : SpottyPalette.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(SpottyPalette.navigationControl, in: Circle())
            }
            .onHover { homeIsHovered = $0 }
            .accessibilityLabel("Home")
            .help("Home")
            .focusable()
            .focusEffectDisabled()
            .focused($focusedControl, equals: .home)
            HStack(spacing: 12) {
                Button {
                    showSearch()
                    focusedControl = .search
                } label: {
                    NavigationSymbol(kind: .search)
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(
                            focusedControl == .search || searchIsHovered
                                ? SpottyPalette.textPrimary : SpottyPalette.textSecondary
                        )
                }
                .accessibilityLabel("Search")
                .keyboardShortcut("l", modifiers: .command)
                TextField("What do you want to play?", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focusedControl, equals: .search)
                    .accessibilityLabel("Search Spotify")
                    .onSubmit(showSearch)
                    .onTapGesture { showSearch() }
            }
            .onHover { searchIsHovered = $0 }
            .padding(.horizontal, 16)
            .frame(maxWidth: 460)
            .frame(height: 48)
            .background(SpottyPalette.navigationControl, in: Capsule())
            .overlay {
                Capsule().strokeBorder(focusedControl == .search ? SpottyPalette.textPrimary : .clear, lineWidth: 2)
            }
            Spacer(minLength: 80)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 18))
        .padding(.leading, 100)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
        .background {
            Color.black
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        }
        .background { WindowButtonAlignment() }
        .onChange(of: searchText) {
            if !searchText.isEmpty { showSearch() }
        }
        .defaultFocus($focusedControl, .home)
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
