import SwiftUI

/// Uppercase caption above a group of rows ("REACH IT", "RESOURCES").
struct SectionHeader: View {
    let title: String

    init(_ title: LocalizedStringResource) { self.title = String(localized: title) }
    @_disfavoredOverload
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(DS.Font.sectionHeader)
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Label on the left, value on the right; monospaced values stay selectable.
struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    init(_ key: LocalizedStringResource, _ value: String, monospaced: Bool = false) {
        self.init(String(localized: key), value, monospaced: monospaced)
    }

    @_disfavoredOverload
    init(_ key: String, _ value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: DS.Spacing.s)
            Text(value)
                .font(monospaced ? DS.Font.monoSmall : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// The rounded, hairline-bordered surface used for cards and groups.
struct CardBackground: ViewModifier {
    var padding: CGFloat = DS.Spacing.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.separator)
            )
    }
}

extension View {
    func card(padding: CGFloat = DS.Spacing.l) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

#Preview("Layout") {
    VStack(alignment: .leading, spacing: 10) {
        SectionHeader("Reach it")
        KeyValueRow("IP on shop_default", "192.168.64.4", monospaced: true)
        KeyValueRow("Restart", "unless-stopped")
    }
    .card()
    .padding()
    .frame(width: 360)
}

extension View {
    /// A card that opens something: clickable, reachable with Tab (Full
    /// Keyboard Access), opened with Return or Space, and by VoiceOver's
    /// default action. Focused, the card's edge (`cornerRadius`) turns
    /// accent: the hover outline's place and width, at full strength. Whole
    /// points, so the edge is even on a 1x display too.
    func cardAction(cornerRadius: CGFloat, _ open: @escaping () -> Void) -> some View {
        modifier(CardAction(cornerRadius: cornerRadius, open: open))
    }
}

private struct CardAction: ViewModifier {
    let cornerRadius: CGFloat
    let open: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture(perform: open)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(DS.accent, lineWidth: focused ? 2 : 0))
            .onKeyPress(.return) { open(); return .handled }
            .onKeyPress(.space) { open(); return .handled }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
    }
}

extension View {
    /// A one-pixel edge along `shape`. Half a point on Retina; on a 1x
    /// display, where half a point breaks up along curves, a whole point
    /// drawn lighter so it keeps the same weight.
    func hairline<S: InsettableShape>(_ shape: S, _ color: Color) -> some View {
        modifier(Hairline(shape: shape, color: color))
    }
}

private struct Hairline<S: InsettableShape>: ViewModifier {
    let shape: S
    let color: Color
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.overlay(shape
            .strokeBorder(color, lineWidth: scale < 2 ? 1 : 0.5)
            .opacity(scale < 2 ? 0.6 : 1))
    }
}

/// A raised surface on the window background: filled, softly shadowed,
/// with a hairline edge. The redesign's cards (Overview hero, map, activity).
struct PanelBackground: ViewModifier {
    var padding: CGFloat = DS.Spacing.l + DS.Spacing.xs

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .fill(DS.raised)
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            )
            .hairline(RoundedRectangle(cornerRadius: DS.Radius.panel), DS.separator.opacity(0.5))
    }
}

extension View {
    func panel(padding: CGFloat = DS.Spacing.l + DS.Spacing.xs) -> some View {
        modifier(PanelBackground(padding: padding))
    }
}

/// A canvas backdrop: faint dots on a regular grid, like a drawing board.
/// Behind maps that can be arranged by hand.
struct DotGrid: View {
    var spacing: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            let dot = Color.primary.opacity(0.09)
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(dot))
                    x += spacing
                }
                y += spacing
            }
        }
        .background(DS.canvas)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A small control or legend floating over a canvas: glass with a hairline.
    func floatingPanel() -> some View {
        padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control + 4))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control + 4).strokeBorder(DS.separator))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// Content that changes while the pointer is over it (actions that show on
/// hover). Keyboard and VoiceOver users reach the same actions from the
/// context menu.
struct HoverReveal<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

/// Content drawn at `scale`, taking the space it then covers: laid out at
/// the available width divided by the scale, so zooming out shows more of
/// it side by side and zooming in makes it scroll.
struct Zoomed<Content: View>: View {
    let scale: Double
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 800
    @State private var height: CGFloat = 400

    var body: some View {
        Color.clear
            .frame(height: height * scale)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .topLeading) {
                content
                    .frame(width: width / scale)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .animation(.snappy, value: scale)
    }
}
