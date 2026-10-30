import SwiftUI

/// The app logo: an open box with its lid lifted and a smaller box inside
/// (ireko-bako, boxes that nest), on an indigo tile. The flat twin of
/// `Resources/AppIcon.icon`; used in-app and as the Dock icon of the
/// SwiftPM build, which has no icon of its own.
public struct BrandLogo: View {
    public var size: CGFloat
    public init(size: CGFloat = 64) { self.size = size }

    static let tile = LinearGradient(colors: [Color(hex: 0x2b4c8c), Color(hex: 0x16294f)],
                                     startPoint: .top, endPoint: .bottom)

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Self.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: max(1, size * 0.01))
                )
            ForEach(Self.faces.indices, id: \.self) { index in
                Polygon(Self.faces[index].points).fill(Self.faces[index].color)
            }
        }
        .frame(width: size, height: size)
    }

    private struct Face {
        let color: Color
        let points: [CGPoint]
        init(_ hex: UInt32, _ points: [(Double, Double)]) {
            color = Color(hex: hex)
            self.points = points.map { CGPoint(x: $0.0, y: $0.1) }
        }
    }

    /// Back to front: the box's inside, the small box, the box's walls and
    /// rim, the lid. Generated from the icon's layers (1024-point canvas).
    private static let faces: [Face] = [
        // back
        Face(0xa9a49a, [(0.5000, 0.5785), (0.2537, 0.7207), (0.2537, 0.5895), (0.5000, 0.4473)]),
        Face(0x88847c, [(0.5000, 0.5785), (0.7463, 0.7207), (0.7463, 0.5895), (0.5000, 0.4473)]),
        Face(0x716d66, [(0.5000, 0.5785), (0.7463, 0.7207), (0.5000, 0.8629), (0.2537, 0.7207)]),
        // core
        Face(0xd39a37, [(0.3863, 0.7207), (0.5000, 0.7863), (0.5000, 0.6426), (0.3863, 0.5770)]),
        Face(0xac7e2d, [(0.6137, 0.7207), (0.5000, 0.7863), (0.5000, 0.6426), (0.6137, 0.5770)]),
        Face(0xe8b65f, [(0.5000, 0.5113), (0.6137, 0.5770), (0.5000, 0.6426), (0.3863, 0.5770)]),
        // front
        Face(0xdbd4c7, [(0.2294, 0.7207), (0.5000, 0.8770), (0.5000, 0.7457), (0.2294, 0.5895)]),
        Face(0xaea99e, [(0.7706, 0.7207), (0.5000, 0.8770), (0.5000, 0.7457), (0.7706, 0.5895)]),
        Face(0xf0ebe0, [(0.5000, 0.4332), (0.7706, 0.5895), (0.7463, 0.5895), (0.5000, 0.4473)]),
        Face(0xf0ebe0, [(0.7706, 0.5895), (0.5000, 0.7457), (0.5000, 0.7316), (0.7463, 0.5895)]),
        Face(0xf0ebe0, [(0.5000, 0.7457), (0.2294, 0.5895), (0.2537, 0.5895), (0.5000, 0.7316)]),
        Face(0xf0ebe0, [(0.2294, 0.5895), (0.5000, 0.4332), (0.5000, 0.4473), (0.2537, 0.5895)]),
        // lid
        Face(0xe7e0d1, [(0.2077, 0.3301), (0.5000, 0.4988), (0.5000, 0.4676), (0.2077, 0.2988)]),
        Face(0xbcb7ab, [(0.7923, 0.3301), (0.5000, 0.4988), (0.5000, 0.4676), (0.7923, 0.2988)]),
        Face(0xf1ece2, [(0.5000, 0.1301), (0.7923, 0.2988), (0.5000, 0.4676), (0.2077, 0.2988)]),
    ]
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

/// A polygon from normalized (0...1) points, scaled to the view's rect.
struct Polygon: Shape {
    let points: [CGPoint]
    init(_ points: [CGPoint]) { self.points = points }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, p) in points.enumerated() {
            let point = CGPoint(x: rect.minX + p.x * rect.width,
                                y: rect.minY + p.y * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Logo + wordmark, for headers (menu bar, settings, install gate).
public struct BrandMark: View {
    public var size: CGFloat
    public var showTagline: Bool
    public init(size: CGFloat = 28, showTagline: Bool = false) {
        self.size = size
        self.showTagline = showTagline
    }

    public var body: some View {
        HStack(spacing: 10) {
            BrandLogo(size: size)
            VStack(alignment: .leading, spacing: 0) {
                Text(Brand.name).font(.system(size: size * 0.55, weight: .semibold))
                if showTagline {
                    Text(Brand.tagline).font(.system(size: size * 0.40)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
