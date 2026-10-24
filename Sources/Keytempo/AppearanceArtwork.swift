import AppKit
import SwiftUI
import TypingCore

/// Bounded vector ornament. These paths have no clock, random seed, image asset,
/// filter or offscreen blur; a theme changes both their geometry and palette.
struct ThemeArtwork: View {
    let theme: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            let colors = AppAppearanceStyle.spectrum(theme: theme, scheme: scheme)
            let strength = contrast == .increased ? 0.28 : scheme == .dark ? 0.68 : 0.50
            let w = size.width, h = size.height
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: w * x, y: h * y) }
            func stroke(_ path: Path, _ index: Int, width: CGFloat = 1) {
                context.stroke(path, with: .linearGradient(Gradient(colors: [colors[index % colors.count].opacity(strength * 0.12), colors[index % colors.count].opacity(strength), colors[(index + 1) % colors.count].opacity(strength * 0.7)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            switch theme {
            case "ocean":
                for i in 0..<9 {
                    let t = Double(i) * 0.064
                    var p = Path(); p.move(to: point(-0.08, 0.3 + t))
                    p.addCurve(to: point(1.08, 0.12 + t), control1: point(0.35, -0.23 + t), control2: point(0.57, 1.04 + t))
                    stroke(p, i, width: i.isMultiple(of: 3) ? 1.7 : 0.7)
                }
            case "prism":
                for i in 0..<7 {
                    let t = Double(i) * 0.065
                    var p = Path(); p.move(to: point(0.18 + t, 0.92)); p.addLine(to: point(0.52 + t * 0.2, 0.02))
                    p.addLine(to: point(1.04 - t * 0.15, 0.79 - t)); p.closeSubpath()
                    stroke(p, i, width: i == 0 ? 1.6 : 0.75)
                }
            case "forest":
                for i in 0..<8 {
                    let t = Double(i) * 0.07
                    var p = Path(); p.move(to: point(0.12 + t, 1.02))
                    p.addCurve(to: point(0.94, -0.03), control1: point(-0.06 + t, 0.36), control2: point(0.46 + t, -0.1))
                    p.addCurve(to: point(0.12 + t, 1.02), control1: point(0.98, 0.64), control2: point(0.56 + t, 1.0))
                    stroke(p, i, width: i == 0 ? 1.5 : 0.8)
                }
            case "ember":
                for i in 0..<9 {
                    let t = Double(i) * 0.055
                    var p = Path(); p.move(to: point(0.05 + t, 1.06))
                    p.addCurve(to: point(0.85 + t * 0.4, -0.08), control1: point(1.13 - t, 0.65), control2: point(0.3 + t, 0.44))
                    stroke(p, i, width: i.isMultiple(of: 4) ? 2.4 : 0.75)
                }
            case "graphite":
                for i in 0..<7 {
                    let t = Double(i) * 0.085
                    var p = Path(); p.move(to: point(0.12, 0.28 + t)); p.addLine(to: point(0.56, 0.02 + t))
                    p.addLine(to: point(1.02, 0.28 + t)); p.addLine(to: point(0.56, 0.56 + t)); p.closeSubpath()
                    stroke(p, i, width: i.isMultiple(of: 3) ? 1.5 : 0.75)
                }
            case "stellar":
                for i in 0..<4 {
                    var layer = context
                    layer.translateBy(x: w * 0.59, y: h * 0.52)
                    layer.rotate(by: .degrees(Double(i) * 37 - 35))
                    let rect = CGRect(x: -w * 0.39, y: -h * 0.3, width: w * 0.78, height: h * 0.6)
                    layer.stroke(Path(ellipseIn: rect), with: .color(colors[i % colors.count].opacity(strength * 0.65)), lineWidth: 0.8)
                }
                for i in 0..<11 {
                    let x = 0.18 + Double((i * 37) % 79) / 100
                    let y = 0.10 + Double((i * 23) % 83) / 100
                    let r: CGFloat = i.isMultiple(of: 4) ? 2.1 : 1.1
                    context.fill(Path(ellipseIn: CGRect(x: w * x - r, y: h * y - r, width: r * 2, height: r * 2)), with: .color(colors[i % colors.count].opacity(strength)))
                }
            case "rose":
                for i in 0..<9 {
                    let radius = 0.51 - Double(i) * 0.035
                    var p = Path()
                    for j in 0...120 {
                        let a = Double(j) / 120 * .pi * 2
                        let r = radius * (0.85 + 0.15 * cos(5 * a + Double(i) * 0.23))
                        let pt = point(0.61 + cos(a) * r * 0.75, 0.5 + sin(a) * r)
                        if j == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath(); stroke(p, i, width: i.isMultiple(of: 3) ? 1.25 : 0.65)
                }
            case "aurora":
                for i in 0..<12 {
                    let t = Double(i) * 0.036
                    var p = Path(); p.move(to: point(-0.04, 0.82 + t))
                    p.addCurve(to: point(1.05, 0.32 + t), control1: point(0.30, -0.42 + t), control2: point(0.68, 1.41 - t))
                    stroke(p, i, width: i.isMultiple(of: 4) ? 3 : 0.9)
                }
                for i in 0..<7 {
                    let x = 0.24 + Double((i * 17) % 70) / 100
                    let y = 0.15 + Double((i * 29) % 66) / 100
                    var p = Path(); p.move(to: point(x - 0.009, y)); p.addLine(to: point(x + 0.009, y))
                    p.move(to: point(x, y - 0.022)); p.addLine(to: point(x, y + 0.022))
                    stroke(p, i, width: 0.8)
                }
            default:
                for i in 0..<5 {
                    let y = 0.3 + Double(i) * 0.1
                    var p = Path(); p.move(to: point(0.14, y))
                    p.addCurve(to: point(1.04, y - 0.12), control1: point(0.45, y + 0.35), control2: point(0.64, y - 0.4))
                    stroke(p, i, width: i == 2 ? 1.8 : 0.8)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension AppAppearanceStyle {
    static func spectrum(theme: String, scheme: ColorScheme) -> [Color] {
        let accent = accent(theme: theme, scheme: scheme)
        let bright = scheme == .dark
        let secondary: Color, tertiary: Color
        switch theme {
        case "ocean": secondary = Color(red: 0.20, green: 0.70, blue: 0.78); tertiary = Color(red: 0.34, green: 0.49, blue: 0.85)
        case "prism": secondary = Color(red: 0.84, green: 0.48, blue: 0.70); tertiary = Color(red: 0.30, green: 0.73, blue: 0.80)
        case "forest": secondary = Color(red: 0.62, green: 0.66, blue: 0.26); tertiary = Color(red: 0.23, green: 0.63, blue: 0.52)
        case "ember": secondary = Color(red: 0.88, green: 0.40, blue: 0.42); tertiary = Color(red: 0.89, green: 0.68, blue: 0.29)
        case "graphite": secondary = Color(red: 0.52, green: 0.61, blue: 0.69); tertiary = Color(red: 0.71, green: 0.69, blue: 0.61)
        case "stellar": secondary = Color(red: 0.46, green: 0.62, blue: 0.84); tertiary = Color(red: 0.79, green: 0.61, blue: 0.39)
        case "rose": secondary = Color(red: 0.77, green: 0.50, blue: 0.35); tertiary = Color(red: 0.65, green: 0.47, blue: 0.73)
        case "aurora": secondary = Color(red: 0.22, green: 0.77, blue: 0.66); tertiary = Color(red: 0.87, green: 0.48, blue: 0.74)
        default: secondary = Color(red: 0.31, green: 0.64, blue: 0.61); tertiary = Color(red: 0.52, green: 0.62, blue: 0.67)
        }
        return [accent, secondary.opacity(bright ? 1 : 0.9), tertiary.opacity(bright ? 1 : 0.9)]
    }
    static func panel(theme: String, scheme: ColorScheme) -> Color {
        canvas(theme: theme, scheme: scheme).opacity(scheme == .dark ? 0.55 : 0.42)
    }
    static func rankTheme(level: Int) -> String {
        AppearanceCatalog.themes.last { level >= $0.level }?.id ?? "classic"
    }
}

/// A theme seal keeps the same faceted silhouette and radial detail at every
/// level; the selected theme supplies its symbol and palette.
struct RankSeal: View {
    let theme: String
    var size: CGFloat = 64
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var colors: [Color] { AppAppearanceStyle.spectrum(theme: theme, scheme: scheme) }
    private var symbol: String { AppearanceCatalog.themes.first { $0.id == theme }?.symbol ?? "circle.hexagongrid" }

    init(theme: String, level _: Int, size: CGFloat = 64) {
        self.theme = theme; self.size = size
    }

    var body: some View {
        ZStack {
            Canvas { context, bounds in
                let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
                let radius = bounds.width / 2
                func polygon(_ r: CGFloat, points: Int, rotation: Double) -> Path {
                    var p = Path()
                    for i in 0..<points {
                        let a = Double(i) / Double(points) * 2 * .pi + rotation
                        let v = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
                        if i == 0 { p.move(to: v) } else { p.addLine(to: v) }
                    }
                    p.closeSubpath(); return p
                }
                let outline = polygon(radius * 0.78, points: 6, rotation: -.pi / 2)
                context.fill(outline, with: .linearGradient(Gradient(colors: [colors[0].opacity(scheme == .dark ? 0.22 : 0.13), colors[1].opacity(0.04), colors[2].opacity(0.17)]), startPoint: .zero, endPoint: CGPoint(x: bounds.width, y: bounds.height)))
                context.stroke(outline, with: .linearGradient(Gradient(colors: [colors[1], colors[0].opacity(0.4), colors[2]]), startPoint: .zero, endPoint: CGPoint(x: bounds.width, y: bounds.height)), lineWidth: size > 50 ? 1.25 : 1)
                context.stroke(polygon(radius * 0.64, points: 6, rotation: -.pi / 2), with: .color(colors[0].opacity(contrast == .increased ? 0.7 : 0.25)), lineWidth: 0.65)
                for i in 0..<6 {
                    let a = Double(i) / 6 * .pi * 2 - .pi / 2
                    var p = Path()
                    let inner = radius * (i.isMultiple(of: 3) ? 0.83 : 0.88)
                    p.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                    p.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.96, y: center.y + sin(a) * radius * 0.96))
                    context.stroke(p, with: .color(colors[i % colors.count].opacity(0.8)), style: StrokeStyle(lineWidth: size > 50 ? 1.3 : 0.9, lineCap: .round))
                }
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.31, weight: .regular))
                .symbolRenderingMode(.hierarchical).foregroundStyle(colors[0])
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct LevelProgressTrack: View {
    let value: Double
    let theme: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.2 : 0.08))
                Capsule().fill(LinearGradient(colors: AppAppearanceStyle.spectrum(theme: theme, scheme: scheme), startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * min(1, max(0, value.isFinite ? value : 0)))
            }
        }.frame(height: 5).accessibilityHidden(true)
    }
}

enum MenuIconSpeedState: Int, CaseIterable, Sendable {
    case idle, slow, steady, fast, peak
}

/// The visible menu and its settings preview use the same 18-point drawing.
/// Five static icons and three icons with five speed states cache at most twenty
/// images. Level never changes detail; the system supplies template appearance.
@MainActor enum MenuIconRenderer {
    private static var images: [String: NSImage] = [:]
    nonisolated static func speedState(wpm: Double?) -> MenuIconSpeedState {
        guard let wpm, wpm.isFinite, wpm > 0 else { return .idle }
        if wpm < 40 { return .slow }
        if wpm < 80 { return .steady }
        if wpm < 120 { return .fast }
        return .peak
    }
    nonisolated static func isSpeedResponsive(style: String) -> Bool {
        style == "rhythm" || style == "ripple" || style == "comet"
    }
    static func image(style: String, level _: Int, wpm: Double? = nil) -> NSImage {
        let normalized = AppearanceCatalog.icons.contains { $0.id == style } ? style : "keyboard"
        let state = speedState(wpm: wpm)
        let key = isSpeedResponsive(style: normalized) ? "\(normalized)-\(state.rawValue)" : normalized
        if let cached = images[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            func line(_ points: [NSPoint], width: CGFloat = 1.25, close: Bool = false) {
                guard let first = points.first else { return }
                let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.move(to: first); for point in points.dropFirst() { path.line(to: point) }
                if close { path.close() }; path.stroke()
            }
            func sparkle(x: CGFloat, y: CGFloat, radius: CGFloat) {
                let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y + radius))
                p.line(to: NSPoint(x: x + radius * 0.28, y: y + radius * 0.28)); p.line(to: NSPoint(x: x + radius, y: y))
                p.line(to: NSPoint(x: x + radius * 0.28, y: y - radius * 0.28)); p.line(to: NSPoint(x: x, y: y - radius))
                p.line(to: NSPoint(x: x - radius * 0.28, y: y - radius * 0.28)); p.line(to: NSPoint(x: x - radius, y: y))
                p.line(to: NSPoint(x: x - radius * 0.28, y: y + radius * 0.28)); p.close(); p.fill()
            }
            switch normalized {
            case "rhythm":
                let profiles: [[CGFloat]] = [[2, 4, 2], [3, 7, 3], [3, 5, 9, 5, 3], [4, 8, 12, 8, 4], [5, 10, 15, 10, 5]]
                let heights = profiles[state.rawValue]
                for (index, height) in heights.enumerated() {
                    let x = 9 + (CGFloat(index) - CGFloat(heights.count - 1) / 2) * 2.8
                    line([NSPoint(x: x, y: 9 - height / 2), NSPoint(x: x, y: 9 + height / 2)], width: index == heights.count / 2 ? 1.7 : 1.25)
                }
            case "ripple":
                let radii: [[CGFloat]] = [[3.2], [4.7], [3.3, 6.3], [2.6, 5, 7.4], [2.6, 5, 7.4]]
                let segments = [1, 1, 2, 2, 3][state.rawValue]
                let gap: CGFloat = [0, 24, 18, 24, 22][state.rawValue]
                for (ring, radius) in radii[state.rawValue].enumerated() {
                    for segment in 0..<segments {
                        let start = CGFloat(segment) / CGFloat(segments) * 360 + CGFloat(ring) * 18 + gap / 2
                        let end = CGFloat(segment + 1) / CGFloat(segments) * 360 + CGFloat(ring) * 18 - gap / 2
                        let arc = NSBezierPath()
                        arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: radius, startAngle: start, endAngle: end, clockwise: false)
                        arc.lineWidth = ring == 0 ? 1.15 : 0.95; arc.lineCapStyle = .round; arc.stroke()
                    }
                }
                NSBezierPath(ovalIn: NSRect(x: 8.2, y: 8.2, width: 1.6, height: 1.6)).fill()
            case "comet":
                let trailCount = state.rawValue
                let head: CGFloat = state == .idle ? 9 : 12.1
                sparkle(x: head, y: head, radius: state == .idle ? 2.6 : 3.1)
                let length: CGFloat = [0, 2.8, 4, 5.2, 6.5][trailCount]
                let diagonal = CGFloat(1 / sqrt(2.0))
                for index in 0..<trailCount {
                    let offset = (CGFloat(index) - CGFloat(trailCount - 1) / 2) * 2.2
                    let end = NSPoint(x: head - 4 * diagonal + offset * diagonal, y: head - 4 * diagonal - offset * diagonal)
                    let start = NSPoint(x: end.x - length * diagonal, y: end.y - length * diagonal)
                    line([start, end], width: 1.1)
                }
            case "wave":
                let heights: [CGFloat] = [4, 7, 11, 7, 4]
                for (i, height) in heights.enumerated() {
                    let x = CGFloat(i) * 2.8 + 3.4
                    line([NSPoint(x: x, y: 9 - height / 2), NSPoint(x: x, y: 9 + height / 2)], width: i == 2 ? 1.8 : 1.3)
                }
                line([NSPoint(x: 4.8, y: 2), NSPoint(x: 13.2, y: 2)], width: 0.8)
            case "orbit":
                let circle = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)); circle.lineWidth = 1.1; circle.stroke()
                let orbit = NSBezierPath(ovalIn: NSRect(x: 0.8, y: 5.1, width: 16.4, height: 7.8))
                let transform = AffineTransform(translationByX: -9, byY: -9)
                orbit.transform(using: transform)
                var rotation = AffineTransform(); rotation.rotate(byDegrees: 33); orbit.transform(using: rotation)
                orbit.transform(using: AffineTransform(translationByX: 9, byY: 9)); orbit.lineWidth = 0.9; orbit.stroke()
                NSBezierPath(ovalIn: NSRect(x: 7.5, y: 7.5, width: 3, height: 3)).fill()
            case "spark":
                sparkle(x: 8.3, y: 8.9, radius: 5.8)
                sparkle(x: 14.6, y: 14.3, radius: 2.0)
                sparkle(x: 3.0, y: 3.0, radius: 1.4)
            case "bolt":
                let p = NSBezierPath(); p.move(to: NSPoint(x: 10.5, y: 16.2)); p.line(to: NSPoint(x: 4.4, y: 8.0))
                p.line(to: NSPoint(x: 8.4, y: 8.0)); p.line(to: NSPoint(x: 7.3, y: 1.8)); p.line(to: NSPoint(x: 14.1, y: 10.4))
                p.line(to: NSPoint(x: 10.1, y: 10.4)); p.close(); p.fill()
                line([NSPoint(x: 2.1, y: 6.7), NSPoint(x: 2.1, y: 11.0), NSPoint(x: 5.1, y: 14.6)], width: 0.85)
            default:
                let rect = NSBezierPath(roundedRect: NSRect(x: 1.7, y: 4.6, width: 14.6, height: 9), xRadius: 2, yRadius: 2)
                rect.lineWidth = 1.1; rect.stroke()
                for row in 0..<2 { for column in 0..<5 {
                    NSBezierPath(roundedRect: NSRect(x: 3.6 + CGFloat(column) * 2.4, y: 8.6 + CGFloat(row) * 2.3, width: 1.25, height: 1.1), xRadius: 0.25, yRadius: 0.25).fill()
                } }
                line([NSPoint(x: 5.8, y: 6.9), NSPoint(x: 12.2, y: 6.9)], width: 1)
                line([NSPoint(x: 3.3, y: 2.0), NSPoint(x: 14.7, y: 2.0)], width: 0.8)
            }
            return true
        }
        image.isTemplate = true
        images[key] = image
        return image
    }
}
