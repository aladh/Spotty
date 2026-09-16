import SwiftUI

extension View {
    /// Owns the recurring hover lifecycle for recyclable cards and rows.
    func hoverSurface(isHovering: Binding<Bool>) -> some View {
        modifier(HoverSurfaceModifier(isHovering: isHovering))
    }
}

private struct HoverSurfaceModifier: ViewModifier {
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            // A recycled surface under a resting cursor keeps no stale highlight.
            .onDisappear { isHovering = false }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}
