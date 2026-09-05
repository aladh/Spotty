import SwiftUI

/// Transport glyphs drawn on the player's 16-point icon grid.
struct TransportSymbol: Shape {
    enum Kind { case play, pause, previous, next, shuffle, repeatAll, repeatOne }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .play:
            path.addLines([CGPoint(x: 3, y: 1), CGPoint(x: 15, y: 8), CGPoint(x: 3, y: 15)])
            path.closeSubpath()
        case .pause:
            path.addRect(CGRect(x: 3, y: 1, width: 3, height: 14))
            path.addRect(CGRect(x: 10, y: 1, width: 3, height: 14))
        case .next, .previous:
            path.addLines([CGPoint(x: 1, y: 1), CGPoint(x: 11, y: 8), CGPoint(x: 1, y: 15)])
            path.closeSubpath()
            path.addRect(CGRect(x: 12, y: 1, width: 3, height: 14))
            if kind == .previous {
                path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 16, ty: 0))
            }
        case .shuffle:
            // Exact vector geometry from Spotify.app/Contents/Resources/Touchbar_Shuffle.pdf.
            path.move(to: CGPoint(x: 12.525333, y: 2.467983))
            path.addCurve(
                to: CGPoint(x: 12.338217, y: 1.999049), control1: CGPoint(x: 12.403895, y: 2.342249),
                control2: CGPoint(x: 12.336698, y: 2.173847))
            path.addCurve(
                to: CGPoint(x: 12.533455, y: 1.533437), control1: CGPoint(x: 12.339737, y: 1.824252),
                control2: CGPoint(x: 12.409850, y: 1.657044))
            path.addCurve(
                to: CGPoint(x: 12.999065, y: 1.338201), control1: CGPoint(x: 12.657060, y: 1.409832),
                control2: CGPoint(x: 12.824267, y: 1.339719))
            path.addCurve(
                to: CGPoint(x: 13.468000, y: 1.525317), control1: CGPoint(x: 13.173864, y: 1.336681),
                control2: CGPoint(x: 13.342265, y: 1.403879))
            path.addLine(to: CGPoint(x: 15.942667, y: 3.999984))
            path.addLine(to: CGPoint(x: 13.468000, y: 6.474651))
            path.addCurve(
                to: CGPoint(x: 13.251603, y: 6.624051), control1: CGPoint(x: 13.406502, y: 6.538324),
                control2: CGPoint(x: 13.332939, y: 6.589111))
            path.addCurve(
                to: CGPoint(x: 12.994268, y: 6.678151), control1: CGPoint(x: 13.170268, y: 6.658991),
                control2: CGPoint(x: 13.082788, y: 6.677381))
            path.addCurve(
                to: CGPoint(x: 12.736031, y: 6.628531), control1: CGPoint(x: 12.905748, y: 6.678920),
                control2: CGPoint(x: 12.817961, y: 6.662053))
            path.addCurve(
                to: CGPoint(x: 12.517069, y: 6.482913), control1: CGPoint(x: 12.654100, y: 6.595011),
                control2: CGPoint(x: 12.579665, y: 6.545509))
            path.addCurve(
                to: CGPoint(x: 12.371452, y: 6.263953), control1: CGPoint(x: 12.454474, y: 6.420319),
                control2: CGPoint(x: 12.404973, y: 6.345884))
            path.addCurve(
                to: CGPoint(x: 12.321833, y: 6.005716), control1: CGPoint(x: 12.337931, y: 6.182023),
                control2: CGPoint(x: 12.321064, y: 6.094235))
            path.addCurve(
                to: CGPoint(x: 12.375932, y: 5.748381), control1: CGPoint(x: 12.322603, y: 5.917197),
                control2: CGPoint(x: 12.340993, y: 5.829717))
            path.addCurve(
                to: CGPoint(x: 12.525333, y: 5.531984), control1: CGPoint(x: 12.410871, y: 5.667045),
                control2: CGPoint(x: 12.461660, y: 5.593482))
            path.addLine(to: CGPoint(x: 13.390667, y: 4.666651))
            path.addLine(to: CGPoint(x: 12.378667, y: 4.666651))
            path.addCurve(
                to: CGPoint(x: 10.972014, y: 4.977721), control1: CGPoint(x: 11.892714, y: 4.666565),
                control2: CGPoint(x: 11.412618, y: 4.772735))
            path.addCurve(
                to: CGPoint(x: 9.828000, y: 5.853317), control1: CGPoint(x: 10.531410, y: 5.182707),
                control2: CGPoint(x: 10.140954, y: 5.481550))
            path.addLine(to: CGPoint(x: 4.930667, y: 11.673317))
            path.addCurve(
                to: CGPoint(x: 3.329345, y: 12.899825), control1: CGPoint(x: 4.492687, y: 12.194001),
                control2: CGPoint(x: 3.946148, y: 12.612613))
            path.addCurve(
                to: CGPoint(x: 1.360000, y: 13.335983), control1: CGPoint(x: 2.712541, y: 13.187037),
                control2: CGPoint(x: 2.040395, y: 13.335899))
            path.addLine(to: CGPoint(x: 0.666667, y: 13.335983))
            path.addLine(to: CGPoint(x: 0.666667, y: 12.002650))
            path.addLine(to: CGPoint(x: 1.360000, y: 12.002650))
            path.addCurve(
                to: CGPoint(x: 2.766741, y: 11.691278), control1: CGPoint(x: 1.846006, y: 12.002653),
                control2: CGPoint(x: 2.326134, y: 11.896381))
            path.addCurve(
                to: CGPoint(x: 3.910667, y: 10.815317), control1: CGPoint(x: 3.207349, y: 11.486176),
                control2: CGPoint(x: 3.597776, y: 11.187205))
            path.addLine(to: CGPoint(x: 8.807333, y: 4.995317))
            path.addCurve(
                to: CGPoint(x: 10.409348, y: 3.768892), control1: CGPoint(x: 9.245521, y: 4.474584),
                control2: CGPoint(x: 9.792304, y: 4.055994))
            path.addCurve(
                to: CGPoint(x: 12.379333, y: 3.333317), control1: CGPoint(x: 11.026393, y: 3.481790),
                control2: CGPoint(x: 11.698766, y: 3.333125))
            path.addLine(to: CGPoint(x: 13.391333, y: 3.333317))
            path.addLine(to: CGPoint(x: 12.525333, y: 2.467983))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12.525333, y: 9.525983))
            path.addCurve(
                to: CGPoint(x: 12.330143, y: 9.997317), control1: CGPoint(x: 12.400353, y: 9.651002),
                control2: CGPoint(x: 12.330143, y: 9.820541))
            path.addCurve(
                to: CGPoint(x: 12.525333, y: 10.468651), control1: CGPoint(x: 12.330143, y: 10.174093),
                control2: CGPoint(x: 12.400353, y: 10.343632))
            path.addLine(to: CGPoint(x: 13.390667, y: 11.333317))
            path.addLine(to: CGPoint(x: 12.378667, y: 11.333317))
            path.addCurve(
                to: CGPoint(x: 10.972014, y: 11.022247), control1: CGPoint(x: 11.892714, y: 11.333402),
                control2: CGPoint(x: 11.412618, y: 11.227233))
            path.addCurve(
                to: CGPoint(x: 9.828000, y: 10.146651), control1: CGPoint(x: 10.531410, y: 10.817262),
                control2: CGPoint(x: 10.140954, y: 10.518418))
            path.addLine(to: CGPoint(x: 8.892667, y: 9.034651))
            path.addLine(to: CGPoint(x: 8.022000, y: 10.070651))
            path.addLine(to: CGPoint(x: 8.807333, y: 11.003984))
            path.addCurve(
                to: CGPoint(x: 10.408957, y: 12.230632), control1: CGPoint(x: 9.245385, y: 11.524753),
                control2: CGPoint(x: 9.792031, y: 11.943416))
            path.addCurve(
                to: CGPoint(x: 12.378667, y: 12.666651), control1: CGPoint(x: 11.025883, y: 12.517847),
                control2: CGPoint(x: 11.698159, y: 12.666665))
            path.addLine(to: CGPoint(x: 13.390667, y: 12.666651))
            path.addLine(to: CGPoint(x: 12.525333, y: 13.531984))
            path.addCurve(
                to: CGPoint(x: 12.375932, y: 13.748381), control1: CGPoint(x: 12.461660, y: 13.593482),
                control2: CGPoint(x: 12.410871, y: 13.667045))
            path.addCurve(
                to: CGPoint(x: 12.321833, y: 14.005716), control1: CGPoint(x: 12.340993, y: 13.829716),
                control2: CGPoint(x: 12.322603, y: 13.917196))
            path.addCurve(
                to: CGPoint(x: 12.371452, y: 14.263953), control1: CGPoint(x: 12.321064, y: 14.094236),
                control2: CGPoint(x: 12.337931, y: 14.182023))
            path.addCurve(
                to: CGPoint(x: 12.517069, y: 14.482914), control1: CGPoint(x: 12.404973, y: 14.345884),
                control2: CGPoint(x: 12.454474, y: 14.420319))
            path.addCurve(
                to: CGPoint(x: 12.736031, y: 14.628531), control1: CGPoint(x: 12.579665, y: 14.545509),
                control2: CGPoint(x: 12.654100, y: 14.595011))
            path.addCurve(
                to: CGPoint(x: 12.994268, y: 14.678151), control1: CGPoint(x: 12.817961, y: 14.662053),
                control2: CGPoint(x: 12.905748, y: 14.678920))
            path.addCurve(
                to: CGPoint(x: 13.251603, y: 14.624052), control1: CGPoint(x: 13.082788, y: 14.677381),
                control2: CGPoint(x: 13.170268, y: 14.658991))
            path.addCurve(
                to: CGPoint(x: 13.468000, y: 14.474651), control1: CGPoint(x: 13.332939, y: 14.589113),
                control2: CGPoint(x: 13.406502, y: 14.538324))
            path.addLine(to: CGPoint(x: 15.942667, y: 11.999984))
            path.addLine(to: CGPoint(x: 13.468000, y: 9.524650))
            path.addCurve(
                to: CGPoint(x: 12.996667, y: 9.329459), control1: CGPoint(x: 13.342981, y: 9.399669),
                control2: CGPoint(x: 13.173443, y: 9.329459))
            path.addCurve(
                to: CGPoint(x: 12.525333, y: 9.524650), control1: CGPoint(x: 12.819891, y: 9.329459),
                control2: CGPoint(x: 12.650353, y: 9.399669))
            path.addLine(to: CGPoint(x: 12.525333, y: 9.525983))
            path.closeSubpath()
            path.move(to: CGPoint(x: 4.930667, y: 4.326650))
            path.addLine(to: CGPoint(x: 6.279333, y: 5.929318))
            path.addLine(to: CGPoint(x: 5.408000, y: 6.964650))
            path.addLine(to: CGPoint(x: 3.910667, y: 5.184651))
            path.addCurve(
                to: CGPoint(x: 2.766653, y: 4.309054), control1: CGPoint(x: 3.597713, y: 4.812884),
                control2: CGPoint(x: 3.207257, y: 4.514040))
            path.addCurve(
                to: CGPoint(x: 1.360000, y: 3.997983), control1: CGPoint(x: 2.326049, y: 4.104068),
                control2: CGPoint(x: 1.845953, y: 3.997899))
            path.addLine(to: CGPoint(x: 0.666667, y: 3.997983))
            path.addLine(to: CGPoint(x: 0.666667, y: 2.664650))
            path.addLine(to: CGPoint(x: 1.360000, y: 2.664650))
            path.addCurve(
                to: CGPoint(x: 3.329257, y: 3.100507), control1: CGPoint(x: 2.040342, y: 2.664653),
                control2: CGPoint(x: 2.712457, y: 2.813412))
            path.addCurve(
                to: CGPoint(x: 4.930667, y: 4.326650), control1: CGPoint(x: 3.946057, y: 3.387602),
                control2: CGPoint(x: 4.492623, y: 3.806089))
            path.closeSubpath()
        case .repeatAll:
            // Exact vector geometry from Spotify.app/Contents/Resources/Touchbar_Repeat.pdf.
            path.move(to: CGPoint(x: 4.000000, y: 1.333333))
            path.addCurve(
                to: CGPoint(x: 2.724389, y: 1.587068), control1: CGPoint(x: 3.562260, y: 1.333333),
                control2: CGPoint(x: 3.128807, y: 1.419553))
            path.addCurve(
                to: CGPoint(x: 1.642977, y: 2.309644), control1: CGPoint(x: 2.319970, y: 1.754584),
                control2: CGPoint(x: 1.952506, y: 2.000115))
            path.addCurve(
                to: CGPoint(x: 0.666667, y: 4.666667), control1: CGPoint(x: 1.017856, y: 2.934765),
                control2: CGPoint(x: 0.666667, y: 3.782612))
            path.addLine(to: CGPoint(x: 0.666667, y: 10.000000))
            path.addCurve(
                to: CGPoint(x: 1.642977, y: 12.357023), control1: CGPoint(x: 0.666667, y: 10.884055),
                control2: CGPoint(x: 1.017856, y: 11.731901))
            path.addCurve(
                to: CGPoint(x: 2.724389, y: 13.079599), control1: CGPoint(x: 1.952506, y: 12.666551),
                control2: CGPoint(x: 2.319970, y: 12.912083))
            path.addCurve(
                to: CGPoint(x: 4.000000, y: 13.333333), control1: CGPoint(x: 3.128807, y: 13.247115),
                control2: CGPoint(x: 3.562260, y: 13.333333))
            path.addLine(to: CGPoint(x: 4.666667, y: 13.333333))
            path.addLine(to: CGPoint(x: 4.666667, y: 12.000000))
            path.addLine(to: CGPoint(x: 4.000000, y: 12.000000))
            path.addCurve(
                to: CGPoint(x: 2.585787, y: 11.414214), control1: CGPoint(x: 3.469567, y: 12.000000),
                control2: CGPoint(x: 2.960859, y: 11.789286))
            path.addCurve(
                to: CGPoint(x: 2.000000, y: 10.000000), control1: CGPoint(x: 2.210714, y: 11.039141),
                control2: CGPoint(x: 2.000000, y: 10.530433))
            path.addLine(to: CGPoint(x: 2.000000, y: 4.666667))
            path.addCurve(
                to: CGPoint(x: 2.585787, y: 3.252453), control1: CGPoint(x: 2.000000, y: 4.136233),
                control2: CGPoint(x: 2.210714, y: 3.627525))
            path.addCurve(
                to: CGPoint(x: 4.000000, y: 2.666667), control1: CGPoint(x: 2.960859, y: 2.877380),
                control2: CGPoint(x: 3.469567, y: 2.666667))
            path.addLine(to: CGPoint(x: 12.000000, y: 2.666667))
            path.addCurve(
                to: CGPoint(x: 13.414214, y: 3.252453), control1: CGPoint(x: 12.530433, y: 2.666667),
                control2: CGPoint(x: 13.039141, y: 2.877380))
            path.addCurve(
                to: CGPoint(x: 14.000000, y: 4.666667), control1: CGPoint(x: 13.789286, y: 3.627525),
                control2: CGPoint(x: 14.000000, y: 4.136233))
            path.addLine(to: CGPoint(x: 14.000000, y: 10.000000))
            path.addCurve(
                to: CGPoint(x: 13.414214, y: 11.414214), control1: CGPoint(x: 14.000000, y: 10.530433),
                control2: CGPoint(x: 13.789286, y: 11.039141))
            path.addCurve(
                to: CGPoint(x: 12.000000, y: 12.000000), control1: CGPoint(x: 13.039141, y: 11.789286),
                control2: CGPoint(x: 12.530433, y: 12.000000))
            path.addLine(to: CGPoint(x: 8.801333, y: 12.000000))
            path.addLine(to: CGPoint(x: 9.666667, y: 11.134667))
            path.addCurve(
                to: CGPoint(x: 9.816067, y: 10.918270), control1: CGPoint(x: 9.730340, y: 11.073169),
                control2: CGPoint(x: 9.781128, y: 10.999606))
            path.addCurve(
                to: CGPoint(x: 9.870167, y: 10.660935), control1: CGPoint(x: 9.851007, y: 10.836935),
                control2: CGPoint(x: 9.869397, y: 10.749454))
            path.addCurve(
                to: CGPoint(x: 9.820548, y: 10.402697), control1: CGPoint(x: 9.870936, y: 10.572415),
                control2: CGPoint(x: 9.854068, y: 10.484628))
            path.addCurve(
                to: CGPoint(x: 9.674930, y: 10.183737), control1: CGPoint(x: 9.787027, y: 10.320767),
                control2: CGPoint(x: 9.737525, y: 10.246332))
            path.addCurve(
                to: CGPoint(x: 9.455969, y: 10.038119), control1: CGPoint(x: 9.612335, y: 10.121141),
                control2: CGPoint(x: 9.537900, y: 10.071639))
            path.addCurve(
                to: CGPoint(x: 9.197732, y: 9.988500), control1: CGPoint(x: 9.374039, y: 10.004599),
                control2: CGPoint(x: 9.286252, y: 9.987731))
            path.addCurve(
                to: CGPoint(x: 8.940397, y: 10.042599), control1: CGPoint(x: 9.109213, y: 9.989269),
                control2: CGPoint(x: 9.021733, y: 10.007660))
            path.addCurve(
                to: CGPoint(x: 8.724000, y: 10.192000), control1: CGPoint(x: 8.859061, y: 10.077539),
                control2: CGPoint(x: 8.785498, y: 10.128327))
            path.addLine(to: CGPoint(x: 6.248667, y: 12.666667))
            path.addLine(to: CGPoint(x: 8.724000, y: 15.141333))
            path.addCurve(
                to: CGPoint(x: 9.192934, y: 15.328449), control1: CGPoint(x: 8.849735, y: 15.262771),
                control2: CGPoint(x: 9.018137, y: 15.329969))
            path.addCurve(
                to: CGPoint(x: 9.658546, y: 15.133212), control1: CGPoint(x: 9.367732, y: 15.326930),
                control2: CGPoint(x: 9.534940, y: 15.256817))
            path.addCurve(
                to: CGPoint(x: 9.853783, y: 14.667601), control1: CGPoint(x: 9.782151, y: 15.009607),
                control2: CGPoint(x: 9.852264, y: 14.842399))
            path.addCurve(
                to: CGPoint(x: 9.666667, y: 14.198667), control1: CGPoint(x: 9.855301, y: 14.492803),
                control2: CGPoint(x: 9.788105, y: 14.324402))
            path.addLine(to: CGPoint(x: 8.801333, y: 13.333333))
            path.addLine(to: CGPoint(x: 12.000000, y: 13.333333))
            path.addCurve(
                to: CGPoint(x: 13.275612, y: 13.079599), control1: CGPoint(x: 12.437739, y: 13.333333),
                control2: CGPoint(x: 12.871193, y: 13.247115))
            path.addCurve(
                to: CGPoint(x: 14.357023, y: 12.357023), control1: CGPoint(x: 13.680031, y: 12.912083),
                control2: CGPoint(x: 14.047494, y: 12.666551))
            path.addCurve(
                to: CGPoint(x: 15.079599, y: 11.275612), control1: CGPoint(x: 14.666551, y: 12.047494),
                control2: CGPoint(x: 14.912083, y: 11.680031))
            path.addCurve(
                to: CGPoint(x: 15.333333, y: 10.000000), control1: CGPoint(x: 15.247115, y: 10.871193),
                control2: CGPoint(x: 15.333333, y: 10.437739))
            path.addLine(to: CGPoint(x: 15.333333, y: 4.666667))
            path.addCurve(
                to: CGPoint(x: 15.079599, y: 3.391055), control1: CGPoint(x: 15.333333, y: 4.228927),
                control2: CGPoint(x: 15.247115, y: 3.795474))
            path.addCurve(
                to: CGPoint(x: 14.357023, y: 2.309644), control1: CGPoint(x: 14.912083, y: 2.986636),
                control2: CGPoint(x: 14.666551, y: 2.619173))
            path.addCurve(
                to: CGPoint(x: 13.275612, y: 1.587068), control1: CGPoint(x: 14.047494, y: 2.000115),
                control2: CGPoint(x: 13.680031, y: 1.754584))
            path.addCurve(
                to: CGPoint(x: 12.000000, y: 1.333333), control1: CGPoint(x: 12.871193, y: 1.419553),
                control2: CGPoint(x: 12.437739, y: 1.333333))
            path.addLine(to: CGPoint(x: 4.000000, y: 1.333333))
            path.closeSubpath()
        case .repeatOne:
            // Exact vector geometry from Spotify.app/Contents/Resources/Touchbar_Repeat_one.pdf.
            path.move(to: CGPoint(x: 7.588000, y: 1.677331))
            path.addCurve(
                to: CGPoint(x: 7.886667, y: 1.031331), control1: CGPoint(x: 7.792000, y: 1.461998),
                control2: CGPoint(x: 7.886667, y: 1.210664))
            path.addLine(to: CGPoint(x: 9.220000, y: 1.031331))
            path.addLine(to: CGPoint(x: 9.220000, y: 7.333331))
            path.addLine(to: CGPoint(x: 7.886667, y: 7.333331))
            path.addLine(to: CGPoint(x: 7.886667, y: 3.333331))
            path.addLine(to: CGPoint(x: 6.666667, y: 3.333331))
            path.addLine(to: CGPoint(x: 6.666667, y: 1.999997))
            path.addLine(to: CGPoint(x: 6.918667, y: 1.999997))
            path.addCurve(
                to: CGPoint(x: 7.588000, y: 1.677331), control1: CGPoint(x: 7.146000, y: 1.999997),
                control2: CGPoint(x: 7.389333, y: 1.886665))
            path.closeSubpath()
            path.move(to: CGPoint(x: 0.666667, y: 4.666665))
            path.addCurve(
                to: CGPoint(x: 1.642977, y: 2.309641), control1: CGPoint(x: 0.666667, y: 3.782610),
                control2: CGPoint(x: 1.017856, y: 2.934763))
            path.addCurve(
                to: CGPoint(x: 4.000000, y: 1.333331), control1: CGPoint(x: 2.268099, y: 1.684521),
                control2: CGPoint(x: 3.115945, y: 1.333331))
            path.addLine(to: CGPoint(x: 4.666667, y: 1.333331))
            path.addLine(to: CGPoint(x: 4.666667, y: 2.666664))
            path.addLine(to: CGPoint(x: 4.000000, y: 2.666664))
            path.addCurve(
                to: CGPoint(x: 2.585787, y: 3.252451), control1: CGPoint(x: 3.469567, y: 2.666664),
                control2: CGPoint(x: 2.960859, y: 2.877379))
            path.addCurve(
                to: CGPoint(x: 2.000000, y: 4.666665), control1: CGPoint(x: 2.210714, y: 3.627524),
                control2: CGPoint(x: 2.000000, y: 4.136232))
            path.addLine(to: CGPoint(x: 2.000000, y: 9.999998))
            path.addCurve(
                to: CGPoint(x: 2.585787, y: 11.414212), control1: CGPoint(x: 2.000000, y: 10.530431),
                control2: CGPoint(x: 2.210714, y: 11.039139))
            path.addCurve(
                to: CGPoint(x: 4.000000, y: 11.999997), control1: CGPoint(x: 2.960859, y: 11.789285),
                control2: CGPoint(x: 3.469567, y: 11.999997))
            path.addLine(to: CGPoint(x: 4.666667, y: 11.999997))
            path.addLine(to: CGPoint(x: 4.666667, y: 13.333331))
            path.addLine(to: CGPoint(x: 4.000000, y: 13.333331))
            path.addCurve(
                to: CGPoint(x: 2.724389, y: 13.079596), control1: CGPoint(x: 3.562260, y: 13.333331),
                control2: CGPoint(x: 3.128807, y: 13.247112))
            path.addCurve(
                to: CGPoint(x: 1.642977, y: 12.357020), control1: CGPoint(x: 2.319970, y: 12.912080),
                control2: CGPoint(x: 1.952506, y: 12.666549))
            path.addCurve(
                to: CGPoint(x: 0.666667, y: 9.999998), control1: CGPoint(x: 1.017856, y: 11.731899),
                control2: CGPoint(x: 0.666667, y: 10.884053))
            path.addLine(to: CGPoint(x: 0.666667, y: 4.666665))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12.000000, y: 2.666664))
            path.addLine(to: CGPoint(x: 11.333333, y: 2.666664))
            path.addLine(to: CGPoint(x: 11.333333, y: 1.333331))
            path.addLine(to: CGPoint(x: 12.000000, y: 1.333331))
            path.addCurve(
                to: CGPoint(x: 13.275612, y: 1.587067), control1: CGPoint(x: 12.437739, y: 1.333331),
                control2: CGPoint(x: 12.871193, y: 1.419550))
            path.addCurve(
                to: CGPoint(x: 14.357023, y: 2.309641), control1: CGPoint(x: 13.680031, y: 1.754581),
                control2: CGPoint(x: 14.047494, y: 2.000113))
            path.addCurve(
                to: CGPoint(x: 15.079599, y: 3.391053), control1: CGPoint(x: 14.666551, y: 2.619171),
                control2: CGPoint(x: 14.912083, y: 2.986634))
            path.addCurve(
                to: CGPoint(x: 15.333333, y: 4.666665), control1: CGPoint(x: 15.247115, y: 3.795471),
                control2: CGPoint(x: 15.333333, y: 4.228925))
            path.addLine(to: CGPoint(x: 15.333333, y: 9.999998))
            path.addCurve(
                to: CGPoint(x: 15.079599, y: 11.275610), control1: CGPoint(x: 15.333333, y: 10.437737),
                control2: CGPoint(x: 15.247115, y: 10.871191))
            path.addCurve(
                to: CGPoint(x: 14.357023, y: 12.357020), control1: CGPoint(x: 14.912083, y: 11.680028),
                control2: CGPoint(x: 14.666551, y: 12.047491))
            path.addCurve(
                to: CGPoint(x: 13.275612, y: 13.079596), control1: CGPoint(x: 14.047494, y: 12.666548),
                control2: CGPoint(x: 13.680031, y: 12.912080))
            path.addCurve(
                to: CGPoint(x: 12.000000, y: 13.333331), control1: CGPoint(x: 12.871193, y: 13.247112),
                control2: CGPoint(x: 12.437739, y: 13.333331))
            path.addLine(to: CGPoint(x: 8.801333, y: 13.333331))
            path.addLine(to: CGPoint(x: 9.666667, y: 14.198664))
            path.addCurve(
                to: CGPoint(x: 9.862135, y: 14.670095), control1: CGPoint(x: 9.791761, y: 14.323669),
                control2: CGPoint(x: 9.862073, y: 14.493248))
            path.addCurve(
                to: CGPoint(x: 9.667000, y: 15.141663), control1: CGPoint(x: 9.862197, y: 14.846941),
                control2: CGPoint(x: 9.792005, y: 15.016569))
            path.addCurve(
                to: CGPoint(x: 9.195569, y: 15.337133), control1: CGPoint(x: 9.541995, y: 15.266758),
                control2: CGPoint(x: 9.372415, y: 15.337070))
            path.addCurve(
                to: CGPoint(x: 8.724000, y: 15.141997), control1: CGPoint(x: 9.018722, y: 15.337195),
                control2: CGPoint(x: 8.849095, y: 15.267002))
            path.addLine(to: CGPoint(x: 6.248667, y: 12.666664))
            path.addLine(to: CGPoint(x: 8.724000, y: 10.191998))
            path.addCurve(
                to: CGPoint(x: 9.192934, y: 10.004882), control1: CGPoint(x: 8.849735, y: 10.070559),
                control2: CGPoint(x: 9.018137, y: 10.003363))
            path.addCurve(
                to: CGPoint(x: 9.658546, y: 10.200119), control1: CGPoint(x: 9.367732, y: 10.006401),
                control2: CGPoint(x: 9.534940, y: 10.076513))
            path.addCurve(
                to: CGPoint(x: 9.853783, y: 10.665731), control1: CGPoint(x: 9.782151, y: 10.323724),
                control2: CGPoint(x: 9.852264, y: 10.490933))
            path.addCurve(
                to: CGPoint(x: 9.666667, y: 11.134664), control1: CGPoint(x: 9.855301, y: 10.840528),
                control2: CGPoint(x: 9.788105, y: 11.008929))
            path.addLine(to: CGPoint(x: 8.801333, y: 11.999997))
            path.addLine(to: CGPoint(x: 12.000000, y: 11.999997))
            path.addCurve(
                to: CGPoint(x: 13.414214, y: 11.414211), control1: CGPoint(x: 12.530433, y: 11.999997),
                control2: CGPoint(x: 13.039141, y: 11.789285))
            path.addCurve(
                to: CGPoint(x: 14.000000, y: 9.999998), control1: CGPoint(x: 13.789286, y: 11.039139),
                control2: CGPoint(x: 14.000000, y: 10.530431))
            path.addLine(to: CGPoint(x: 14.000000, y: 4.666665))
            path.addCurve(
                to: CGPoint(x: 13.414214, y: 3.252451), control1: CGPoint(x: 14.000000, y: 4.136231),
                control2: CGPoint(x: 13.789286, y: 3.627524))
            path.addCurve(
                to: CGPoint(x: 12.000000, y: 2.666664), control1: CGPoint(x: 13.039141, y: 2.877377),
                control2: CGPoint(x: 12.530433, y: 2.666664))
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}
