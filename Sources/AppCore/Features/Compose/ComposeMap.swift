import SwiftUI
import ContainerKit

/// Where each service goes on the map, in rows top to bottom: services
/// published on this Mac first, then what they depend on, row by row; the
/// rest below them. With nothing published, the services nothing depends
/// on come first.
enum ComposeTopology {
    static func rows(_ services: [ComposeService], top: Set<String> = []) -> [[String]] {
        let names = Set(services.map(\.name))
        let top = top.intersection(names)
        var dependents: [String: [String]] = [:]
        for service in services {
            for dependency in service.dependsOn where names.contains(dependency) {
                dependents[dependency, default: []].append(service.name)
            }
        }
        var depth: [String: Int] = [:]
        func resolve(_ name: String, _ visiting: Set<String>) -> Int {
            if let known = depth[name] { return known }
            if top.contains(name) { depth[name] = 0; return 0 }
            let parents = (dependents[name] ?? []).filter { !visiting.contains($0) }   // ignore cycles
            let value = parents.map { resolve($0, visiting.union([name])) + 1 }.max() ?? (top.isEmpty ? 0 : 1)
            depth[name] = value
            return value
        }
        for name in names { _ = resolve(name, []) }
        let count = (depth.values.max() ?? -1) + 1
        return (0..<count).map { row in depth.filter { $0.value == row }.map(\.key).sorted() }.filter { !$0.isEmpty }
    }
}

/// The project as a picture, top to bottom: this Mac with the ports it
/// publishes, wired to their services in the first row; below, what those
/// depend on, row by row. Cards show image, state, local names and storage,
/// and can be dragged. Once one is, every card keeps its spot (measured
/// from the map's top left, so the window's width doesn't move them); new
/// services go in a row below.
struct ComposeMap: View {
    let project: String
    let services: [ComposeService]
    let health: [String: String]
    /// The service shown in the inspector.
    var selected: String? = nil
    /// Live CPU and memory by container id.
    var stats: [String: LiveStats.Series] = [:]
    /// Bumped to lay the cards out again (the Auto Arrange button lives outside).
    var arrangeRequest = 0
    var onSelect: (ComposeService) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    /// Where cards were put (top left, in the cards area); empty = automatic.
    @State private var placed: [String: CGPoint] = [:]
    /// Each card's frame in the cards area, as laid out.
    @State private var frames: [String: CGRect] = [:]
    @State private var dragging: (name: String, from: CGPoint, by: CGSize)?
    @State private var areaWidth: CGFloat = 800
    private static let space = "compose-map-cards"
    @State private var hoveredNetwork: String?

    /// Every network the services are on, in a fixed order (by name).
    private var networks: [String] {
        Array(Set(services.flatMap(\.networks))).sorted()
    }

    /// Fixed order, never by rank; the name is always shown beside it.
    private static let networkColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    private func color(of network: String) -> Color {
        guard let index = networks.firstIndex(of: network), index < Self.networkColors.count else { return .gray }
        return Self.networkColors[index]
    }

    private var rows: [[ComposeService]] {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        let published = Set(services.filter { !$0.ports.isEmpty }.map(\.name))
        let rows = MapPlacement.order(ComposeTopology.rows(services, top: published), links: links)
        return rows.map { $0.compactMap { byName[$0] } }
    }

    /// depends_on pairs, for ordering cards so lines cross less.
    private var links: [(String, String)] {
        services.flatMap { service in service.dependsOn.map { (service.name, $0) } }
    }

    /// Tidy rows, centered in the area's width, as pinned spots.
    private func autoArrange() {
        let arranged = MapPlacement.arrange(rows.map { $0.map(\.name) }, sizes: frames.mapValues(\.size),
                                            width: areaWidth)
        withAnimation(reduceMotion ? nil : .snappy) { placed = arranged }
        MapLayoutStore.save(arranged, for: project)
    }

    /// Services with ports on this Mac, in map order.
    private var reachable: [ComposeService] {
        rows.joined().filter { !$0.ports.isEmpty }
    }

    var body: some View {
        VStack(spacing: 56) {
            macNode
            cardsArea
            networkBar
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity)
        .backgroundPreferenceValue(MapAnchors.self) { anchors in
            GeometryReader { proxy in
                // Ways in carry moving dashes while their service runs.
                TimelineView(.animation(paused: reduceMotion || !reachable.contains { $0.tone == .positive })) { timeline in
                    let phase = reduceMotion ? 0 : -timeline.date.timeIntervalSinceReferenceDate * 22
                    edges(anchors, proxy, phase: phase.truncatingRemainder(dividingBy: 24))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project map")
        .onAppear { placed = MapLayoutStore.load(project) }
        .onChange(of: arrangeRequest) { autoArrange() }
    }

    // MARK: - Cards area

    private var cardsArea: some View {
        cardsContent
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { areaWidth = $0 }
    }

    @ViewBuilder
    private var cardsContent: some View {
        if placed.isEmpty {
            VStack(spacing: 56) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    FlowLayout(spacing: DS.Spacing.l) {
                        ForEach(row) { service in
                            card(service).offset(dragOffset(service.name))
                        }
                    }
                    .zIndex(row.contains { $0.name == dragging?.name } ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.space))
        } else {
            let spots = MapPlacement.place(rows.joined().map(\.name), placed: placed,
                                           sizes: frames.mapValues(\.size))
            let extent = MapPlacement.extent(spots, sizes: frames.mapValues(\.size))
            // Wider than the window: scroll sideways rather than move cards.
            ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: extent.width, height: extent.height)
                ForEach(Array(rows.joined())) { service in
                    let spot = spots[service.name] ?? .zero
                    card(service)
                        .padding(.leading, spot.x)
                        .padding(.top, spot.y)
                        .offset(dragOffset(service.name))
                        .zIndex(dragging?.name == service.name ? 1 : 0)
                }
            }
            .coordinateSpace(.named(Self.space))
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func dragOffset(_ name: String) -> CGSize {
        dragging?.name == name ? dragging!.by : .zero
    }

    /// Pin every card where it is, the dragged one where it was dropped.
    private func drop(_ name: String, from origin: CGPoint, by translation: CGSize) {
        var spots = placed.isEmpty
            ? frames.mapValues(\.origin)
            : MapPlacement.place(rows.joined().map(\.name), placed: placed, sizes: frames.mapValues(\.size))
        spots[name] = CGPoint(x: max(0, origin.x + translation.width), y: max(0, origin.y + translation.height))
        placed = spots
        MapLayoutStore.save(spots, for: project)
    }

    // MARK: - This Mac

    private var macNode: some View {
        HStack(spacing: DS.Spacing.s) {
            Text("This Mac").font(.headline)
            if reachable.isEmpty {
                Text("No ports published. Services reach each other by name.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(reachable) { service in
                    ways(into: service)
                        .anchorPreference(key: MapAnchors.self, value: .bounds) { ["in:\(service.name)": $0] }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.s)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.separator))
        // Added to the ways-in anchors inside rather than replacing them.
        .transformAnchorPreference(key: MapAnchors.self, value: .bounds) { $0["mac"] = $1 }
    }

    /// One service's addresses on this Mac.
    private func ways(into service: ComposeService) -> some View {
        let live = service.tone == .positive
        let highlighted = hovered == service.name
        return HStack(spacing: DS.Spacing.xs) {
            ForEach(service.ports) { access in
                let enabled = live && access.url != nil && {
                    if case .port(_, let isLive) = access { return isLive }
                    return true
                }()
                Button {
                    if let url = access.url { openURL(url) }
                } label: {
                    Text(verbatim: "\(access.title) → \(service.name)")
                        .font(DS.Font.monoSmall).lineLimit(1)
                        .foregroundStyle(enabled ? DS.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(enabled ? String(localized: "Open \(access.url!.absoluteString)")
                              : live ? access.title : String(localized: "\(service.name) isn't running"))
            }
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.accent.opacity(highlighted ? 0.2 : live ? 0.1 : 0.05)))
        .onHover { hovered = $0 ? service.name : nil }
    }

    // MARK: - Networks

    @ViewBuilder
    private var networkBar: some View {
        if networks.count == 1, let only = networks.first {
            Label("All services share the network \(shortNetworkName(only, project: project)); they reach each other by service name.",
                  systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption).foregroundStyle(.secondary)
        } else if networks.count > 1 {
            HStack(spacing: DS.Spacing.m) {
                Label("Networks", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(networks, id: \.self) { network in
                    let members = services.filter { $0.networks.contains(network) }.map(\.name)
                    HStack(spacing: DS.Spacing.xs) {
                        Circle().fill(color(of: network)).frame(width: 8, height: 8)
                        Text(shortNetworkName(network, project: project)).font(.caption.weight(.medium))
                        Text(verbatim: "\(members.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Spacing.s).padding(.vertical, 3)
                    .background(Capsule().fill(hoveredNetwork == network ? color(of: network).opacity(0.18) : DS.surface))
                    .overlay(Capsule().strokeBorder(DS.separator))
                    .onHover { hoveredNetwork = $0 ? network : nil }
                    .help("\(network): \(members.joined(separator: ", ")). Services reach each other only on a shared network.")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Services

    private func card(_ service: ComposeService) -> some View {
        let healthStatus = service.containers.lazy.compactMap { health[$0.id] }.first
        let isSelected = selected == service.name
        let highlighted = hovered == service.name || isSelected
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                StatusDot(tone: service.tone, size: 8)
                Text(service.name).font(.headline).lineLimit(1)
                    .help(service.networks.map { shortNetworkName($0, project: project) }.joined(separator: ", "))
                if service.containers.count > 1 {
                    Text(verbatim: "×\(service.containers.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let healthStatus { HealthBadge(status: healthStatus) }
            }
            if !service.image.isEmpty {
                Label(service.image, systemImage: "shippingbox")
                    .font(DS.Font.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            // The state only when it isn't simply "running"; the inspector has the rest.
            if service.tone != .positive {
                Text(service.stateLabel).font(.caption.weight(.medium)).foregroundStyle(service.tone.text)
            }
            if let live = liveLine(service) {
                Sparkline(samples: live.cpu, maxValue: max(10, (live.cpu.max() ?? 0) * 1.2), tone: .info)
                    .frame(height: 18)
                Text(live.text).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            if let mount = service.mounts.first {
                Label(service.mounts.count == 1 ? mount.title : "\(mount.title) +\(service.mounts.count - 1)",
                      systemImage: mount.kind == .folder ? "folder" : "externaldrive")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(service.mounts.map { "\($0.source) → \($0.target)" }.joined(separator: "\n"))
            }
        }
        .padding(DS.Spacing.m)
        .frame(minWidth: 210, idealWidth: 210, maxWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
            .strokeBorder(highlighted ? DS.accent : DS.separator, lineWidth: isSelected ? 3 : highlighted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .shadow(color: .black.opacity(dragging?.name == service.name ? 0.18 : 0.06), radius: dragging?.name == service.name ? 10 : 3, y: dragging?.name == service.name ? 4 : 1)
        .opacity(hoveredNetwork.map { service.networks.contains($0) ? 1 : 0.3 } ?? 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveredNetwork)
        .onHover { hovered = $0 ? service.name : nil }
        .pointerStyle(dragging?.name == service.name ? .grabActive : .grabIdle)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
            if dragging?.name != service.name { frames[service.name] = frame }
        }
        .anchorPreference(key: MapAnchors.self, value: .bounds) { ["svc:\(service.name)": $0] }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let origin = dragging?.from ?? frames[service.name]?.origin ?? .zero
                dragging = (service.name, origin, value.translation)
            }
            .onEnded { value in
                let origin = dragging?.from ?? frames[service.name]?.origin ?? .zero
                drop(service.name, from: origin, by: value.translation)
                dragging = nil
            })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(service.name), \(service.stateLabel)"))
        .accessibilityValue(connections(of: service))
        .accessibilityHint("Shows its details beside the map")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .cardAction(cornerRadius: DS.Radius.card) { onSelect(service) }
    }

    /// "4% · 18 MB · up 3h" and recent CPU of a running service's first container.
    private func liveLine(_ service: ComposeService) -> (text: String, cpu: [Double])? {
        guard let container = service.containers.first(where: { $0.state.isRunning }) else { return nil }
        var parts: [String] = []
        let series = stats[container.id]
        if let cpu = series?.latestCPU { parts.append("\(Int(cpu.rounded()))%") }
        if let memory = series?.memoryUsage, memory > 0 { parts.append(Format.memory(memory)) }
        if let started = container.startedDate { parts.append(String(localized: "up \(Format.duration(Date().timeIntervalSince(started)))", comment: "Uptime, e.g. up 3h")) }
        return parts.isEmpty ? nil : (parts.joined(separator: " · "), series?.cpu ?? [])
    }

    /// The lines around a card, in words (the diagram's lines aren't read).
    private func connections(of service: ComposeService) -> String {
        var parts: [String] = []
        let ports = service.ports.map(\.title)
        if !ports.isEmpty { parts.append(String(localized: "open on this Mac at \(ports.joined(separator: ", "))")) }
        if !service.dependsOn.isEmpty { parts.append(String(localized: "depends on \(service.dependsOn.joined(separator: ", "))")) }
        let users = services.filter { $0.dependsOn.contains(service.name) }.map(\.name)
        if !users.isEmpty { parts.append(String(localized: "used by \(users.joined(separator: ", "))")) }
        if networks.count > 1 { parts.append(String(localized: "networks \(service.networks.map { shortNetworkName($0, project: project) }.joined(separator: ", "))")) }
        return parts.joined(separator: "; ")
    }

    // MARK: - Edges

    private func edges(_ anchors: [String: Anchor<CGRect>], _ proxy: GeometryProxy, phase: Double) -> some View {
        let cards = Dictionary(uniqueKeysWithValues: services.compactMap { service in
            anchors["svc:\(service.name)"].map { (service.name, proxy[$0]) }
        })
        let router = EdgeRouter(cards: Array(cards.values))
        let macBottom = anchors["mac"].map { proxy[$0].maxY }
        return Canvas { context, _ in
            var lane = 0
            // Ways in: this Mac → service.
            for service in reachable {
                guard let from = anchors["in:\(service.name)"], let b = cards[service.name] else { continue }
                let a = proxy[from]
                let live = service.tone == .positive
                let highlighted = hovered == service.name
                let (path, end) = router.route(from: CGPoint(x: a.midX, y: a.maxY), to: b, lane: &lane,
                                               below: macBottom)
                if live {
                    // A faint rail with dashes moving along it: traffic can flow now.
                    context.stroke(path, with: .color(DS.accent.opacity(highlighted ? 0.35 : 0.2)),
                                   style: StrokeStyle(lineWidth: highlighted ? 2.5 : 2, lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: .color(DS.accent.opacity(highlighted ? 1 : 0.8)),
                                   style: StrokeStyle(lineWidth: highlighted ? 2.5 : 2, lineCap: .round, lineJoin: .round,
                                                      dash: [4, 8], dashPhase: phase))
                } else {
                    context.stroke(path, with: .color(Color.secondary.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                }
                context.fill(Path(ellipseIn: CGRect(x: end.point.x - 3.5, y: end.point.y - 3.5, width: 7, height: 7)),
                             with: .color(live ? DS.accent : .secondary))
            }
            // depends_on: service → what it needs, below.
            for service in services {
                for dependency in service.dependsOn {
                    guard let a = cards[service.name], let b = cards[dependency] else { continue }
                    let highlighted = hovered == service.name || hovered == dependency
                    let color = Color.secondary.opacity(highlighted ? 0.9 : 0.55)
                    let (path, end) = router.connect(a, to: b, lane: &lane)
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: highlighted ? 2 : 1.25, lineCap: .round, lineJoin: .round,
                                                      dash: [5, 4]))
                    context.fill(end.arrowHead, with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Draws an edge from a point down to a card: straight in from above when
/// nothing is in the way, else around the cards in between, along the
/// nearer side, into the card's side.
struct EdgeRouter {
    let cards: [CGRect]
    var corner: CGFloat = 10

    struct End {
        let point: CGPoint
        /// Pointing down (into the top) or sideways (into a side).
        let direction: CGVector

        var arrowHead: Path {
            let back = CGPoint(x: point.x - direction.dx * 8, y: point.y - direction.dy * 8)
            let side = CGVector(dx: -direction.dy * 4.5, dy: direction.dx * 4.5)
            var path = Path()
            path.move(to: point)
            path.addLine(to: CGPoint(x: back.x + side.dx, y: back.y + side.dy))
            path.addLine(to: CGPoint(x: back.x - side.dx, y: back.y - side.dy))
            path.closeSubpath()
            return path
        }
    }

    /// From one card to another wherever they are: down into the top (around
    /// cards in between), up into the bottom, or sideways between neighbours.
    func connect(_ a: CGRect, to b: CGRect, lane: inout Int) -> (Path, End) {
        if b.minY > a.maxY + 8 { return route(from: CGPoint(x: a.midX, y: a.maxY), to: b, lane: &lane) }
        var path = Path()
        if a.minY > b.maxY + 8 {
            let start = CGPoint(x: a.midX, y: a.minY), end = CGPoint(x: b.midX, y: b.maxY)
            let bend = max(20, (start.y - end.y) / 2)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y - bend), control2: CGPoint(x: end.x, y: end.y + bend))
            return (path, End(point: end, direction: CGVector(dx: 0, dy: -1)))
        }
        let rightward = b.midX > a.midX
        let start = CGPoint(x: rightward ? a.maxX : a.minX, y: a.midY)
        let end = CGPoint(x: rightward ? b.minX : b.maxX, y: b.midY)
        let bend = max(20, abs(end.x - start.x) / 2) * (rightward ? 1 : -1)
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return (path, End(point: end, direction: CGVector(dx: rightward ? 1 : -1, dy: 0)))
    }

    /// `below`: turn under this line (the box the edge starts in).
    func route(from start: CGPoint, to target: CGRect, lane: inout Int, below: CGFloat? = nil) -> (Path, End) {
        let between = cards.filter { $0.minY > start.y && $0.maxY < target.minY }
        guard !between.isEmpty else {
            let end = CGPoint(x: target.midX, y: target.minY)
            var path = Path()
            path.move(to: start)
            let bend = max(20, (end.y - start.y) / 2)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + bend),
                          control2: CGPoint(x: end.x, y: end.y - bend))
            return (path, End(point: end, direction: CGVector(dx: 0, dy: 1)))
        }
        lane += 1
        let offset = 18 + CGFloat(lane - 1) * 8
        let left = (between.map(\.minX).min() ?? target.minX)
        let right = (between.map(\.maxX).max() ?? target.maxX)
        let goLeft = abs(target.midX - left) <= abs(right - target.midX)
        let gutter = goLeft ? min(left, target.minX) - offset : max(right, target.maxX) + offset
        let top = between.map(\.minY).min() ?? target.minY
        let floor = below ?? start.y
        let turn = min(floor + 10 + CGFloat(lane - 1) * 6, floor + (top - floor) * 0.75)
        let end = CGPoint(x: goLeft ? target.minX : target.maxX, y: target.midY)
        let points = [start, CGPoint(x: start.x, y: turn), CGPoint(x: gutter, y: turn),
                      CGPoint(x: gutter, y: end.y), end]
        var path = Path()
        path.move(to: points[0])
        for index in 1..<(points.count - 1) {
            path.addArc(tangent1End: points[index], tangent2End: points[index + 1], radius: corner)
        }
        path.addLine(to: end)
        return (path, End(point: end, direction: CGVector(dx: goLeft ? 1 : -1, dy: 0)))
    }
}

/// Lays children out in rows, wrapping when the width runs out; each row
/// centered.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, max(width, 0)) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Spots for the cards once any was placed by hand: placed ones where they
/// were put; the others in a row below them, in map order.
enum MapPlacement {
    static let fallbackSize = CGSize(width: 210, height: 140)
    static let gap: CGFloat = 16
    static let rowGap: CGFloat = 56

    /// Reorder each row by where its linked cards sit in the rows next to it
    /// (barycenters, a few sweeps down and up), so lines cross less.
    static func order(_ rows: [[String]], links: [(String, String)]) -> [[String]] {
        var neighbours: [String: Set<String>] = [:]
        for (a, b) in links where a != b {
            neighbours[a, default: []].insert(b)
            neighbours[b, default: []].insert(a)
        }
        var rows = rows
        func sort(_ index: Int, by reference: [String]) {
            let position = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($1, Double($0)) })
            let current = Dictionary(uniqueKeysWithValues: rows[index].enumerated().map { ($1, Double($0)) })
            rows[index] = rows[index].sorted { a, b in
                func key(_ name: String) -> Double {
                    let linked = (neighbours[name] ?? []).compactMap { position[$0] }
                    return linked.isEmpty ? current[name]! : linked.reduce(0, +) / Double(linked.count)
                }
                let (ka, kb) = (key(a), key(b))
                return ka != kb ? ka < kb : current[a]! < current[b]!
            }
        }
        for _ in 0..<3 {
            for index in rows.indices.dropFirst() { sort(index, by: rows[index - 1]) }
            for index in rows.indices.dropLast().reversed() { sort(index, by: rows[index + 1]) }
        }
        return rows
    }

    /// Rows top to bottom, each centered in `width`.
    static func arrange(_ rows: [[String]], sizes: [String: CGSize], width: CGFloat) -> [String: CGPoint] {
        var spots: [String: CGPoint] = [:]
        var y: CGFloat = 0
        for row in rows where !row.isEmpty {
            let widths = row.map { (sizes[$0] ?? fallbackSize).width }
            let total = widths.reduce(0, +) + gap * 2 * CGFloat(row.count - 1)
            var x = max(0, (width - total) / 2)
            for (name, cardWidth) in zip(row, widths) {
                spots[name] = CGPoint(x: x.rounded(), y: y)
                x += cardWidth + gap * 2
            }
            y += (row.map { (sizes[$0] ?? fallbackSize).height }.max() ?? 0) + rowGap
        }
        return spots
    }

    static func place(_ names: [String], placed: [String: CGPoint], sizes: [String: CGSize]) -> [String: CGPoint] {
        var spots = placed.filter { names.contains($0.key) }
        let bottom = spots.map { $0.value.y + (sizes[$0.key] ?? fallbackSize).height }.max()
        var x: CGFloat = 0
        let y = bottom.map { $0 + 56 } ?? 0
        for name in names where spots[name] == nil {
            spots[name] = CGPoint(x: x, y: y)
            x += (sizes[name] ?? fallbackSize).width + gap
        }
        return separated(spots, sizes: sizes)
    }

    /// Spots saved when cards were narrower can overlap now: push each card
    /// right of any earlier one it overlaps (top to bottom, left to right).
    static func separated(_ spots: [String: CGPoint], sizes: [String: CGSize]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        let order = spots.sorted { ($0.value.y, $0.value.x, $0.key) < ($1.value.y, $1.value.x, $1.key) }
        for (name, spot) in order {
            let size = sizes[name] ?? fallbackSize
            var frame = CGRect(origin: spot, size: size)
            var moved = true
            while moved {
                moved = false
                for (other, origin) in result {
                    let otherFrame = CGRect(origin: origin, size: sizes[other] ?? fallbackSize)
                    if frame.intersects(otherFrame.insetBy(dx: -gap / 2, dy: -gap / 2)) {
                        frame.origin.x = otherFrame.maxX + gap
                        moved = true
                    }
                }
            }
            result[name] = frame.origin
        }
        return result
    }

    /// The area the cards cover.
    static func extent(_ spots: [String: CGPoint], sizes: [String: CGSize]) -> CGSize {
        CGSize(width: spots.map { $0.value.x + (sizes[$0.key] ?? fallbackSize).width }.max() ?? 0,
               height: spots.map { $0.value.y + (sizes[$0.key] ?? fallbackSize).height }.max() ?? 0)
    }
}

/// Where cards were put on each project's map.
enum MapLayoutStore {
    private static let key = "composeMapPositions"

    static func load(_ project: String) -> [String: CGPoint] {
        UserDefaults.standard.removeObject(forKey: "composeMapLayout")   // offsets, before positions
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: [Double]]] ?? [:]
        return (all[project] ?? [:]).compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    static func save(_ spots: [String: CGPoint], for project: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: [Double]]] ?? [:]
        all[project] = spots.isEmpty ? nil : spots.mapValues { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(all, forKey: key)
    }
}

struct MapAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
