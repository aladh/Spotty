import SwiftUI

struct PlayerUtilityIcon: View {
    enum Kind { case queue, devices, computer }
    let kind: Kind
    let isOpen: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private let activeColor = Color(red: 29 / 255, green: 185 / 255, blue: 84 / 255)

    var body: some View {
        PlaybackUtilitySymbol(kind: kind)
            .fill(style: FillStyle(eoFill: true))
            .frame(width: 16, height: 16)
            .foregroundStyle(
                isOpen
                    ? (isHovering && isEnabled ? SpottyPalette.mediaGreen : activeColor)
                    : Color.white.opacity(isHovering && isEnabled ? 1 : 0.7)
            )
            .frame(width: 32, height: 32)
            .overlay(alignment: .bottom) {
                if isOpen {
                    Circle().fill(activeColor).frame(width: 4, height: 4)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .accessibilityHidden(true)
    }

}

struct PlaybackUtilitySymbol: Shape {
    let kind: PlayerUtilityIcon.Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .queue:
            // The desktop glyph uses a capsule above two square-ended rules.
            path.addRoundedRect(
                in: CGRect(x: 1, y: 1, width: 14, height: 5), cornerSize: CGSize(width: 2.5, height: 2.5))
            path.addRoundedRect(
                in: CGRect(x: 2.5, y: 2.5, width: 11, height: 2), cornerSize: CGSize(width: 1, height: 1))
            path.addRect(CGRect(x: 1, y: 9, width: 14, height: 1.5))
            path.addRect(CGRect(x: 1, y: 13.5, width: 14, height: 1.5))
        case .computer:
            path.addRoundedRect(
                in: CGRect(x: 2, y: 1, width: 12, height: 11), cornerSize: CGSize(width: 1.75, height: 1.75))
            path.addRoundedRect(
                in: CGRect(x: 3.5, y: 2.5, width: 9, height: 8), cornerSize: CGSize(width: 0.25, height: 0.25))
            path.addRect(CGRect(x: 0, y: 14, width: 16, height: 1.5))
        case .devices:
            path.addRoundedRect(
                in: CGRect(x: 6, y: 1, width: 10, height: 14), cornerSize: CGSize(width: 1.75, height: 1.75))
            path.addRoundedRect(
                in: CGRect(x: 7.5, y: 2.5, width: 7, height: 11), cornerSize: CGSize(width: 0.25, height: 0.25))
            path.addEllipse(in: CGRect(x: 9, y: 8, width: 4, height: 4))
            path.addEllipse(in: CGRect(x: 10, y: 4, width: 2, height: 2))
            path.move(to: CGPoint(x: 4, y: 1))
            path.addLine(to: CGPoint(x: 1.75, y: 1))
            path.addQuadCurve(to: CGPoint(x: 0, y: 2.75), control: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 0, y: 9.25))
            path.addQuadCurve(to: CGPoint(x: 1.75, y: 11), control: CGPoint(x: 0, y: 11))
            path.addLines([CGPoint(x: 4, y: 11), CGPoint(x: 4, y: 9.5), CGPoint(x: 1.75, y: 9.5)])
            path.addQuadCurve(to: CGPoint(x: 1.5, y: 9.25), control: CGPoint(x: 1.5, y: 9.5))
            path.addLine(to: CGPoint(x: 1.5, y: 2.75))
            path.addQuadCurve(to: CGPoint(x: 1.75, y: 2.5), control: CGPoint(x: 1.5, y: 2.5))
            path.addLines([CGPoint(x: 4, y: 2.5), CGPoint(x: 4, y: 1)])
            path.closeSubpath()
            path.addRect(CGRect(x: 2, y: 13.5, width: 2, height: 1.5))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}
