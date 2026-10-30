import SwiftUI
import ContainerKit

/// A cluster as a hierarchy, top to bottom: this Mac and the node ports it
/// reaches; services; workloads, each framing its pods; the ConfigMaps,
/// Secrets and volume claims they use. Lines: Mac → service (node port),
/// service → workload (its selector picks the workload's pods), workload →
/// what it mounts or reads.
struct KubeMap: View {
    let workloads: [KubeWorkload]
    /// Pods no workload owns (static control-plane pods, bare pods).
    var loosePods: [KubePod] = []
    let services: [KubeService]
    /// Service ports leading nowhere, by service id.
    var problems: [String: [KubePortProblem]] = [:]
    let nodeAddress: String?
    let showNamespace: Bool
    let onPod: (KubePod) -> Void
    /// Point a service at the port its pods listen on.
    var onFix: ((KubePortProblem) -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @State private var hovered: String?
    @State private var mapWidth: CGFloat = 0

    /// Services with a port on the node, which this Mac can open.
    private var reachable: [KubeService] { services.filter { $0.ports.contains { $0.nodePort != nil } } }

    private func targets(of service: KubeService) -> [KubeWorkload] {
        workloads.filter { workload in workload.pods.contains(where: service.selects) }
    }

    /// Everything workloads refer to, once per namespace and name.
    private var references: [(namespace: String, reference: KubeReference)] {
        var seen: Set<String> = []
        return workloads.flatMap { workload in workload.references.map { (workload.namespace, $0) } }
            .filter { seen.insert("\($0.namespace)/\($0.reference.id)").inserted }
            .sorted { ($0.reference.kind.rawValue, $0.reference.name) < ($1.reference.kind.rawValue, $1.reference.name) }
    }

    /// Services and workloads in an order that keeps lines short.
    private var orderedServices: [KubeService] {
        services.sorted { (firstIndex(of: $0), $0.name) < (firstIndex(of: $1), $1.name) }
    }

    private func firstIndex(of service: KubeService) -> Int {
        targets(of: service).compactMap { target in workloads.firstIndex { $0.id == target.id } }.min() ?? Int.max
    }

    /// The workload chosen for Scale (clicked on the map).
    var selectedWorkload: String? = nil
    var onSelectWorkload: (KubeWorkload) -> Void = { _ in }

    /// One column per service: how you reach it, the service, the workloads
    /// it sends to. Workloads no service reaches get a column of their own.
    struct Column: Identifiable {
        let service: KubeService?
        let workloads: [KubeWorkload]
        var id: String { service?.id ?? "wl:" + (workloads.first?.id ?? "") }
    }

    var columns: [Column] {
        var placed: Set<String> = []
        var result: [Column] = []
        for service in orderedServices {
            let own = targets(of: service).filter { placed.insert($0.id).inserted }
            result.append(Column(service: service, workloads: own))
        }
        for workload in workloads where !placed.contains(workload.id) {
            result.append(Column(service: nil, workloads: [workload]))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("HOW YOU REACH IT").font(DS.Font.sectionHeader).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 48) {
                    ForEach(columns) { column in columnView(column) }
                }
                .padding(.horizontal, DS.Spacing.s)
                .padding(.bottom, DS.Spacing.s)
                // Centred while the columns fit; scrolling sideways when they don't.
                .frame(minWidth: mapWidth)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mapWidth = $0 }
            if !loosePods.isEmpty { loosePodsNode }
            if !references.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("CONFIGURATION & DATA").font(DS.Font.sectionHeader).foregroundStyle(.secondary)
                    FlowLayout(spacing: DS.Spacing.s) {
                        ForEach(references, id: \.reference.id) { entry in referenceNode(entry.namespace, entry.reference) }
                    }
                }
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .backgroundPreferenceValue(MapAnchors.self) { anchors in
            GeometryReader { proxy in edges(anchors, proxy) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cluster map")
    }

    private func columnView(_ column: Column) -> some View {
        VStack(spacing: 44) {
            reachPill(column.service)
            if let service = column.service { serviceNode(service) }
            VStack(spacing: DS.Spacing.m) {
                ForEach(column.workloads) { workloadNode($0) }
            }
        }
        .frame(width: 290)
    }

    /// The way in at the top of a column: an address to open, a port
    /// nothing answers on, or "inside the cluster only".
    @ViewBuilder
    private func reachPill(_ service: KubeService?) -> some View {
        let problem = service.flatMap { problems[$0.id]?.first }
        let nodePort = service?.ports.compactMap(\.nodePort).first
        Group {
            if let service, let nodePort, let address = nodeAddress {
                if problem != nil {
                    Text(":\(String(nodePort)) — nothing answers")
                        .foregroundStyle(Tone.warning.text)
                        .padding(.horizontal, DS.Spacing.m).padding(.vertical, 5)
                        .background(Capsule().fill(DS.raised))
                        .overlay(Capsule().strokeBorder(Tone.warning.fill.opacity(0.7)))
                } else {
                    Button {
                        if let url = URL(string: "http://\(address):\(nodePort)") { openURL(url) }
                    } label: {
                        Text(verbatim: "\(address):\(nodePort) ↗")
                            .padding(.horizontal, DS.Spacing.m).padding(.vertical, 5)
                            .background(Capsule().fill(DS.raised))
                            .hairline(Capsule(), DS.separator.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .help("Open in the browser")
                    .onHover { hovered = $0 ? service.id : nil }
                }
            } else {
                Text(service == nil ? "Not reachable: no service" : "Inside the cluster only")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.m).padding(.vertical, 5)
                    .background(Capsule().strokeBorder(DS.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .help(service == nil ? "Add a service to reach it" : "Reached by other pods by name; kubectl port-forward opens it here")
            }
        }
        .font(DS.Font.monoSmall)
        .anchorPreference(key: MapAnchors.self, value: .bounds) { anchor in
            service.map { ["in:\($0.id)": anchor] } ?? [:]
        }
    }

    private func serviceNode(_ service: KubeService) -> some View {
        let highlighted = hovered == service.id
        return VStack(alignment: .leading, spacing: 3) {
            Text("SERVICE · the front door").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text(service.name).font(.title3.weight(.bold))
                Text(verbatim: "\(service.type) → " + service.ports.map(\.target).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if showNamespace { Text(service.namespace).font(.caption2).foregroundStyle(.secondary) }
            ForEach(problems[service.id] ?? []) { problem in
                Text(problem.listening.first.map { String(localized: "The app listens on \(String($0)), not \(String(problem.target)).") }
                     ?? problem.displayMessage)
                    .font(.callout).foregroundStyle(Tone.warning.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let onFix, let port = problem.listening.first {
                    Button("Send Traffic to Port \(String(port))") { onFix(problem) }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 2)
                }
            }
        }
        .padding(DS.Spacing.m)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card + 2).fill(DS.raised)
            .shadow(color: .black.opacity(problems[service.id] != nil ? 0 : 0.08), radius: 2, y: 1))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 2)
            .strokeBorder(problems[service.id] != nil ? Tone.warning.fill : highlighted ? DS.accent : DS.separator.opacity(0.4),
                          lineWidth: problems[service.id] != nil || highlighted ? 2 : 0.5))
        .shadow(color: problems[service.id] != nil ? Tone.warning.fill.opacity(0.2) : .clear, radius: 8, y: 3)
        .onHover { hovered = $0 ? service.id : nil }
        .accessibilityElement(children: .combine)
        .accessibilityValue("routes to \(targets(of: service).map(\.name).joined(separator: ", "))")
        .anchorPreference(key: MapAnchors.self, value: .bounds) { ["svc:\(service.id)": $0] }
    }

    private func workloadNode(_ workload: KubeWorkload) -> some View {
        let failing = workload.pods.contains { $0.health == .failing }
        let tone: Tone = failing ? .critical : workload.ready >= workload.desired ? .positive : .warning
        let highlighted = hovered == workload.id
        let selected = selectedWorkload == workload.id
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(workload.kind.title.localizedUppercase) · \(Self.role(of: workload.kind))")
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.xs) {
                Text(workload.name).font(.headline).lineLimit(1)
                Text(verbatim: "×\(workload.desired)").font(.headline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if showNamespace { Text(workload.namespace).font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: DS.Spacing.xs) {
                ForEach(workload.pods) { pod in
                    Button { onPod(pod) } label: {
                        Circle().fill(podTone(pod).fill).frame(width: 11, height: 11)
                    }
                    .buttonStyle(.plain)
                    .help("\(pod.name): \(pod.reason ?? pod.phase) — click for logs and a shell")
                    .accessibilityLabel("Pod \(pod.name)")
                    .accessibilityValue(pod.reason ?? pod.phase)
                }
                Text(failing ? "a pod is failing" : workload.ready < workload.desired ? "\(workload.ready) of \(workload.desired) ready" : "pods are fine")
                    .font(.caption).foregroundStyle(tone == .positive ? Color.secondary : tone.text)
            }
        }
        .padding(DS.Spacing.m)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card + 2).fill(DS.raised)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card + 2)
            .strokeBorder(selected ? DS.accent : highlighted ? DS.accent.opacity(0.6) : DS.separator.opacity(0.4),
                          lineWidth: selected || highlighted ? 2 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card + 2))
        .onTapGesture { onSelectWorkload(workload) }
        .onHover { hovered = $0 ? workload.id : nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workload.kind.title) \(workload.name), \(workload.ready) of \(workload.desired) ready")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Select for scaling") { onSelectWorkload(workload) }
        .anchorPreference(key: MapAnchors.self, value: .bounds) { ["wl:\(workload.id)": $0] }
    }

    /// What each kind of workload does, in a few words.
    static func role(of kind: KubeWorkload.Kind) -> String {
        switch kind.rawValue {
        case "Deployment": String(localized: "keeps copies running")
        case "StatefulSet": String(localized: "keeps copies with their own data")
        case "DaemonSet": String(localized: "one copy on every node")
        case "Job": String(localized: "runs to completion")
        case "CronJob": String(localized: "runs on a schedule")
        default: String(localized: "runs pods")
        }
    }

    private func podTone(_ pod: KubePod) -> Tone {
        pod.health == .ok ? .positive : pod.health == .failing ? .critical : pod.health == .done ? .neutral : .warning
    }

    private var loosePodsNode: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Pods on their own").font(.headline)
            Text("No workload restarts these if they go").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(loosePods) { pod in
                    Button { onPod(pod) } label: { podMark(pod, full: true) }.buttonStyle(.plain)
                        .accessibilityLabel("Pod \(pod.name)")
                        .accessibilityValue(pod.reason ?? pod.phase)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.m)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func podMark(_ pod: KubePod, full: Bool = false) -> some View {
        let tone: Tone = pod.health == .ok ? .positive : pod.health == .failing ? .critical : pod.health == .done ? .neutral : .warning
        return HStack(spacing: 3) {
            Circle().fill(tone.fill).frame(width: 7, height: 7)
            Text(full ? pod.name : String(pod.name.split(separator: "-").last ?? Substring(pod.name)))
                .font(DS.Font.monoSmall).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tone.background))
        .help("\(pod.name): \(pod.reason ?? pod.phase) — click for logs and a shell")
    }

    private func referenceNode(_ namespace: String, _ reference: KubeReference) -> some View {
        let icon: String = switch reference.kind {
        case .configMap: "doc.text"
        case .secret: "key"
        case .volumeClaim: "externaldrive"
        }
        let id = "\(namespace)/\(reference.id)"
        return HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(reference.name).font(DS.Font.monoSmall)
            Text(reference.kind.title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Spacing.s).padding(.vertical, DS.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).strokeBorder(DS.separator))
        .anchorPreference(key: MapAnchors.self, value: .bounds) { ["ref:\(id)": $0] }
    }

    // MARK: - Edges

    private func edges(_ anchors: [String: Anchor<CGRect>], _ proxy: GeometryProxy) -> some View {
        let boxes = anchors.filter { $0.key.hasPrefix("svc:") || $0.key.hasPrefix("wl:") }.map { proxy[$0.value] }
        let router = EdgeRouter(cards: boxes)
        return Canvas { context, _ in
            var lane = 0
            func draw(_ from: String, _ to: String, color: Color, dashed: Bool, highlighted: Bool, arrow: Bool) {
                guard let a = anchors[from].map({ proxy[$0] }), let b = anchors[to].map({ proxy[$0] }) else { return }
                let (path, end) = router.connect(a, to: b, lane: &lane)
                context.stroke(path, with: .color(color.opacity(highlighted ? 1 : 0.6)),
                               style: StrokeStyle(lineWidth: highlighted ? 2.2 : 1.3, lineCap: .round, lineJoin: .round,
                                                  dash: dashed ? [5, 4] : []))
                if arrow { context.fill(end.arrowHead, with: .color(color.opacity(highlighted ? 1 : 0.7))) }
            }
            for service in services {
                let broken = problems[service.id] != nil
                draw("in:\(service.id)", "svc:\(service.id)", color: broken ? Tone.warning.fill : DS.accent, dashed: true,
                     highlighted: hovered == service.id, arrow: false)
            }
            for service in services {
                for workload in targets(of: service) {
                    draw("svc:\(service.id)", "wl:\(workload.id)", color: DS.accent, dashed: false,
                         highlighted: hovered == service.id || hovered == workload.id, arrow: true)
                }
            }
            for workload in workloads {
                for reference in workload.references {
                    draw("wl:\(workload.id)", "ref:\(workload.namespace)/\(reference.id)", color: .secondary, dashed: true,
                         highlighted: hovered == workload.id, arrow: false)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension KubeWorkload.Kind {
    /// The kind as the UI shows it (a Kubernetes term, localized like the glossary).
    var title: String {
        switch self {
        case .deployment: Glossary.deployment.title
        case .statefulSet: Glossary.statefulSet.title
        case .daemonSet: Glossary.daemonSet.title
        }
    }
}

extension KubeReference.Kind {
    /// The kind as the UI shows it.
    var title: String {
        switch self {
        case .configMap: Glossary.configMap.title
        case .secret: Glossary.secret.title
        case .volumeClaim: String(localized: "PVC", comment: "Kubernetes: PersistentVolumeClaim, short")
        }
    }
}

extension KubePortProblem {
    /// `message`, in the app's language.
    var displayMessage: String {
        if loopbackOnly {
            return String(localized: "Its pods listen on \(String(target)) only on 127.0.0.1, so the service can't reach them; make the app listen on 0.0.0.0.")
        }
        if listening.isEmpty {
            return String(localized: "\(service.name) sends to port \(String(target)), and its pods listen on no port.")
        }
        let ports = listening.map(String.init).joined(separator: ", ")
        return String(localized: "\(service.name) sends to port \(String(target)), but its pods listen on \(ports).")
    }
}
