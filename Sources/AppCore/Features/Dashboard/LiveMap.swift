import SwiftUI
import ContainerKit

/// "Everything, live": this Mac at the top, a line to each thing running on
/// it — compose projects, Kubernetes clusters, machines, containers on their
/// own. Lines to running things move; each node opens its screen.
struct LiveMap: View {
    let nodes: [Node]
    let open: (Node) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Node: Identifiable, Equatable {
        enum Kind: Equatable { case compose, cluster, machine, container }

        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        /// One dot per member (service, node), in order.
        let dots: [Tone]
        /// Named volumes it uses, shown as chips.
        var volumes: [String] = []
        /// What's still on its way ("mysql starting").
        var note: String?

        var isLive: Bool { dots.contains(.positive) }
    }

    var body: some View {
        VStack(spacing: 56) {
            Label("This Mac", systemImage: "laptopcomputer")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, DS.Spacing.m)
                .padding(.vertical, DS.Spacing.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control + 4).fill(DS.surface)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1))
                .anchorPreference(key: MapAnchors.self, value: .bounds) { ["mac": $0] }
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: DS.Spacing.l)],
                      spacing: DS.Spacing.l) {
                ForEach(nodes) { node in
                    nodeView(node)
                        .anchorPreference(key: MapAnchors.self, value: .bounds) { [node.id: $0] }
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .top)
        .backgroundPreferenceValue(MapAnchors.self) { anchors in
            GeometryReader { proxy in
                // Lines to running things move; with nothing running the
                // map holds still instead of redrawing every frame.
                TimelineView(.animation(minimumInterval: 1 / 30,
                                        paused: reduceMotion || !nodes.contains(where: \.isLive))) { timeline in
                    let phase = reduceMotion ? 0 : -timeline.date.timeIntervalSinceReferenceDate * 22
                    Canvas { context, _ in
                        guard let mac = anchors["mac"].map({ proxy[$0] }) else { return }
                        let start = CGPoint(x: mac.midX, y: mac.maxY)
                        for node in nodes {
                            guard let frame = anchors[node.id].map({ proxy[$0] }) else { continue }
                            let end = CGPoint(x: frame.midX, y: frame.minY)
                            var path = Path()
                            path.move(to: start)
                            let middle = (start.y + end.y) / 2
                            path.addCurve(to: end, control1: CGPoint(x: start.x, y: middle),
                                          control2: CGPoint(x: end.x, y: middle))
                            if node.isLive {
                                context.stroke(path, with: .color(DS.accent),
                                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 8],
                                                                  dashPhase: phase.truncatingRemainder(dividingBy: 24)))
                            } else {
                                context.stroke(path, with: .color(.secondary.opacity(0.6)),
                                               style: StrokeStyle(lineWidth: 1.4, dash: [3, 4]))
                            }
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.subtleFill.opacity(0.5)))
    }

    private func nodeView(_ node: Node) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: icon(node.kind)).foregroundStyle(DS.accent).font(.caption)
                Text(node.title).font(.callout.weight(.bold)).lineLimit(1)
            }
            Text(node.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: DS.Spacing.xs) {
                ForEach(Array(node.dots.prefix(12).enumerated()), id: \.offset) { _, tone in
                    StatusDot(tone: tone)
                }
                if let note = node.note {
                    Text(note).font(.caption2).foregroundStyle(Tone.warning.text).lineLimit(1)
                }
            }
            if !node.volumes.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(node.volumes.prefix(3), id: \.self) { volume in
                        Text(volume).font(DS.Font.monoSmall).lineLimit(1)
                            .padding(.horizontal, DS.Spacing.s).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.subtleFill))
                    }
                }
            }
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 4).fill(DS.surface)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control + 4))
        .cardAction(cornerRadius: DS.Radius.control + 4) { open(node) }
        .help("Open \(node.title)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(node.title), \(node.subtitle)\(node.note.map { ", \($0)" } ?? "")"))
    }

    private func icon(_ kind: Node.Kind) -> String {
        switch kind {
        case .compose: return SidebarSection.compose.systemImage
        case .cluster: return SidebarSection.kubernetes.systemImage
        case .machine: return SidebarSection.machines.systemImage
        case .container: return SidebarSection.containers.systemImage
        }
    }
}

extension LiveMap.Node {
    /// The map's nodes: one per compose project, cluster, machine and
    /// container on its own, running ones first.
    static func nodes(containers: [Container], clusters: [Cluster], health: [String: String]) -> [LiveMap.Node] {
        func tone(_ container: Container) -> Tone {
            if health[container.id] == "unhealthy" { return .critical }
            if health[container.id] == "starting" { return .warning }
            return ContainerPresentation(container).tone
        }
        var nodes: [LiveMap.Node] = []
        let user = containers.filter { !$0.isSystem }
        for group in ContainerList.group(user) {
            if let project = group.project {
                let services = group.containers.map { $0.serviceName }
                let starting = group.containers.filter { tone($0) == .warning }.map { $0.serviceName }
                let volumes = Set(group.containers.flatMap(\.namedVolumes)).sorted()
                nodes.append(.init(id: "compose:\(project)", kind: .compose, title: project,
                                   subtitle: String(localized: "Compose · \(services.joined(separator: ", "))"),
                                   dots: group.containers.map(tone), volumes: volumes,
                                   note: starting.first.map { String(localized: "\($0) starting") }))
            } else {
                for container in group.containers {
                    nodes.append(.init(id: "container:\(container.id)", kind: .container, title: container.id,
                                       subtitle: String(localized: "\(container.imageShortName) · on its own"),
                                       dots: [tone(container)], volumes: container.namedVolumes))
                }
            }
        }
        for cluster in clusters {
            nodes.append(.init(id: "cluster:\(cluster.name)", kind: .cluster, title: cluster.name,
                               subtitle: String(localized: "Kubernetes · \(cluster.nodes.count) nodes"),
                               dots: cluster.nodes.map { $0.state == "running" ? .positive : .neutral }))
        }
        for machine in containers.filter(\.isMachine) {
            nodes.append(.init(id: "machine:\(machine.id)", kind: .machine, title: machine.machineName ?? machine.id,
                               subtitle: String(localized: "Machine · \(machine.machineImage)"), dots: [tone(machine)]))
        }
        return nodes.enumerated().sorted { a, b in
            a.element.isLive != b.element.isLive ? a.element.isLive : a.offset < b.offset
        }.map(\.element)
    }
}

private extension Container {
    /// Named volumes mounted (not host folders).
    /// "ubuntu:24.04" for a machine on its prepared image
    /// (`irekobox-machine-ubuntu:24.04`).
    var machineImage: String {
        let name = imageShortName
        let prefix = "irekobox-machine-"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    var namedVolumes: [String] { (configuration.mounts ?? []).compactMap(\.volumeName) }
}
