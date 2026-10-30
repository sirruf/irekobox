import SwiftUI
import AppKit
import ContainerKit

/// One cluster: what runs in it (workloads with their pods), the services
/// that reach them, and how to connect kubectl.
struct ClusterView: View {
    let name: String
    let clusters: ClustersModel
    let onDeleted: () -> Void
    @Environment(AppState.self) private var app
    @State private var model: ClusterModel?
    @State private var openPod: KubePod?
    @State private var loadingImage = false
    @State private var showConnect = false
    @State private var confirmDelete = false
    @State private var pendingDelete: KubeWorkload?
    @AppStorage("clusterLayout") private var layout = "map"
    @State private var deploying = false
    @State private var applying: String?
    @State private var pendingServiceDelete: KubeService?
    /// The workload the Scale panel works on.
    @State private var scaling: String?

    private var cluster: Cluster? { clusters.clusters.first { $0.name == name } }

    var body: some View {
        Group {
            if let cluster, let model {
                VStack(spacing: 0) {
                    header(cluster, model)
                    Divider()
                    content(cluster, model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if cluster == nil && clusters.loaded {
                ContentUnavailableView("Cluster Deleted", systemImage: "helm", description: Text("It was deleted."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(name)
        // The list may still be loading when the page opens (a link at launch).
        .onChange(of: cluster?.controlPlane?.name, initial: true) { _, node in
            if model == nil, let node {
                model = ClusterModel(name: name, node: node, cli: app.cli)
            }
        }
        // kubectl can only answer while the nodes run; a stopped cluster
        // shows as such without asking.
        .task(id: "\(model == nil) \(cluster?.isRunning == true)") {
            guard let model, cluster?.isRunning == true else { return }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .sheet(item: $openPod) { pod in
            if let model { PodSheet(pod: pod, model: model).environment(app) }
        }
        .sheet(isPresented: $deploying) {
            if let model {
                RunAppSheet(cluster: name, nodeAddress: cluster?.controlPlane?.address, model: model, clusters: clusters) {
                    applying = $0
                }
                .environment(app)
            }
        }
        .sheet(item: Binding(get: { applying.map { ApplyText(text: $0) } }, set: { applying = $0?.text })) { item in
            if let model { ApplyYAMLSheet(cluster: name, model: model, text: item.text) }
        }
        .confirmationDialog(pendingServiceDelete.map { String(localized: "Delete service “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { pendingServiceDelete != nil },
                                                 set: { if !$0 { pendingServiceDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingServiceDelete) { service in
            Button("Delete", role: .destructive) { Task { await model?.delete(service) } }
        } message: { _ in
            Text("Its pods keep running; they just aren't reachable through it.")
        }
        .sheet(isPresented: $loadingImage) {
            LoadImageSheet(cluster: name, clusters: clusters).environment(app)
        }
        .confirmationDialog("Delete cluster “\(name)”?", isPresented: $confirmDelete) {
            Button("Delete Cluster", role: .destructive) {
                Task { await clusters.delete(name); onDeleted() }
            }
        } message: {
            Text("Its nodes, deployed apps and loaded images are deleted. This can't be undone.")
        }
        .confirmationDialog(pendingDelete.map { String(localized: "Delete \($0.kind.title) “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { workload in
            Button("Delete", role: .destructive) { Task { await model?.delete(workload) } }
        } message: { _ in
            Text("Its pods stop. Services, ConfigMaps and volumes stay.")
        }
    }

    // MARK: - Header

    private func header(_ cluster: Cluster, _ model: ClusterModel) -> some View {
        let pods = model.workloads.flatMap(\.pods) + model.loosePods
        let cpus = cluster.nodes.compactMap(\.cpus).reduce(0, +)
        let problems = model.portProblems.values.reduce(0) { $0 + $1.count }
        return HStack(alignment: .top, spacing: DS.Spacing.m) {
          HStack(alignment: .center, spacing: DS.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(DS.accent.opacity(cluster.isRunning ? 0.15 : 0.06))
                Image(systemName: "helm").font(.title2).foregroundStyle(cluster.isRunning ? DS.accent : .secondary)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(name).font(.title2.weight(.bold))
                    StatusPill(tone: cluster.isRunning ? .positive : .neutral, label: cluster.isRunning ? "Running" : "Stopped")
                    TermInfo(.cluster)
                }
                HStack(spacing: DS.Spacing.m) {
                    Label("\(cluster.nodes.count) nodes", systemImage: "server.rack")
                    Label("\(cpus) CPUs · \(cluster.nodes.compactMap(\.memory).first ?? "?")", systemImage: "cpu")
                    if let address = cluster.controlPlane?.address {
                        Label(address, systemImage: "network").textSelection(.enabled)
                    }
                    Label("\(pods.filter { $0.health == .ok }.count) of \(pods.count) pods running", systemImage: "circle.grid.2x2")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          .panel()
          .frame(maxWidth: .infinity)
          .layoutPriority(1)
            summaryTile("Apps", "\(model.workloads.count)", detail: "\(pods.count) pods")
            summaryTile("Needs attention", "\(problems)", detail: problems == 0 ? "all good" : "port mismatch",
                        tone: problems == 0 ? nil : .warning)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DS.Spacing.l)
        .navigationSubtitle(String(localized: "Kubernetes cluster · \(cluster.nodes.count) nodes"))
        .toolbar {
            // Switching what the window shows: centred, as macOS places view switchers.
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $layout) {
                    Text("Map").tag("map")
                    Text("Cards").tag("cards")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("The cluster as a map, or as cards")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Namespace", selection: Binding(get: { model.namespace }, set: { model.namespace = $0 })) {
                    Text("All my apps").tag(String?.none)
                    Divider()
                    ForEach(model.namespaces, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .fixedSize()
                .help("A namespace is a folder for apps in a cluster")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Load Image…") { loadingImage = true }
                        .help("Copy an image from this Mac into the cluster, for pods to use without a registry")
                    Divider()
                    Toggle("Show Kubernetes' Own Workloads", isOn: Binding(get: { model.showSystem }, set: { model.showSystem = $0 }))
                    Divider()
                    Button("Delete Cluster", role: .destructive) { confirmDelete = true }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More")
                .menuIndicator(.hidden)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Apply YAML…") { applying = "" }
                    .help("Apply your own manifests")
                    .disabled(!cluster.isRunning)
                Button("Connect kubectl") { showConnect = true }
                    .help("Use kubectl or another tool with this cluster")
                    .popover(isPresented: $showConnect, arrowEdge: .bottom) {
                        ConnectPopover(cluster: name, kubeconfig: clusters.kubeconfig(of: name), clusters: clusters)
                    }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Run an App…") { deploying = true }
                    .buttonStyle(.borderedProminent)
                    .help("Run an image in the cluster; Irekobox works out the details")
                    .disabled(!cluster.isRunning)
                    .accessibilityIdentifier("cluster.runApp")
            }
        }
    }

    private func summaryTile(_ title: LocalizedStringKey, _ value: String, detail: LocalizedStringKey, tone: Tone? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(tone?.text ?? .secondary)
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 180, maxHeight: .infinity, alignment: .leading)
        .panel()
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .strokeBorder(tone.map { $0.fill.opacity(0.6) } ?? .clear, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ cluster: Cluster, _ model: ClusterModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Tone.critical.text).lineLimit(1)
                    .padding(.horizontal, DS.Spacing.l).padding(.bottom, DS.Spacing.s)
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Tone.positive.text).lineLimit(1)
                    .padding(.horizontal, DS.Spacing.l).padding(.bottom, DS.Spacing.s)
            }
            if !cluster.isRunning {
                ContentUnavailableView("Cluster Stopped", systemImage: "pause.circle",
                                       description: Text("Its nodes aren't running, so there's nothing to show. Start the engine (Engine menu) if it's stopped; the cluster comes back with it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.snapshot == nil {
                ProgressView("Reading the cluster…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.workloads.isEmpty && model.loosePods.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Deployed Yet", systemImage: "shippingbox")
                } description: {
                    Text("Run an image with Deploy, apply your own manifests, or use kubectl (Connect kubectl shows how).")
                } actions: {
                    Button("Run an App…") { deploying = true }.buttonStyle(.borderedProminent)
                    if !model.showSystem {
                        Button("Show Kubernetes' Own Workloads") { model.showSystem = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layout == "map" {
                ScrollView {
                    KubeMap(workloads: model.workloads, loosePods: model.loosePods, services: model.services,
                            problems: model.portProblems,
                            nodeAddress: cluster.controlPlane?.address, showNamespace: model.namespace == nil,
                            onPod: { openPod = $0 }, onFix: { problem in Task { await model.fix(problem) } },
                            selectedWorkload: scaling ?? model.workloads.first?.id,
                            onSelectWorkload: { scaling = $0.id })
                        .padding(DS.Spacing.l)
                    LearnNote("**Reading the map:** traffic enters at the top, a *Service* routes it, a *Deployment* keeps the right number of *Pods* (copies of your app) alive. Click a pod for its logs.")
                        .padding([.horizontal, .bottom], DS.Spacing.l)
                }
                .background { DotGrid() }
                .overlay(alignment: .bottomTrailing) {
                    if let workload = model.workloads.first(where: { $0.id == (scaling ?? model.workloads.first?.id) }),
                       workload.kind.rawValue == "Deployment" || workload.kind.rawValue == "StatefulSet" {
                        HStack(spacing: DS.Spacing.s) {
                            Text("Scale \(workload.name)").font(.callout).foregroundStyle(.secondary)
                            Button { Task { await model.scale(workload, to: workload.desired - 1) } } label: { Image(systemName: "minus") }
                                .buttonStyle(.automatic)
                                .disabled(workload.desired <= 0 || model.isBusy(workload.id))
                                .accessibilityLabel("Fewer copies")
                            Text(verbatim: "\(workload.desired)").font(.title3.weight(.semibold)).monospacedDigit()
                                .frame(minWidth: 22)
                            Button { Task { await model.scale(workload, to: workload.desired + 1) } } label: { Image(systemName: "plus") }
                                .buttonStyle(.automatic)
                                .disabled(model.isBusy(workload.id))
                                .accessibilityLabel("More copies")
                        }
                        .floatingPanel()
                        .padding(DS.Spacing.l)
                        .help("How many copies Kubernetes keeps running; click another app on the map to scale it")
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                        workloads(cluster, model)
                        services(cluster, model)
                        loosePods(model)
                    }
                    .padding(DS.Spacing.l)
                }
            }
        }
    }

    private static let grid = [GridItem(.adaptive(minimum: 320), spacing: DS.Spacing.l, alignment: .top)]

    /// Open an object's manifest in the YAML sheet.
    private func edit(_ resource: String, _ namespace: String, _ model: ClusterModel) {
        Task {
            if let yaml = await model.editableYAML(resource, namespace: namespace) { applying = yaml }
        }
    }

    @ViewBuilder
    private func workloads(_ cluster: Cluster, _ model: ClusterModel) -> some View {
        if !model.workloads.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ExplainedHeader(title: "Workloads", subtitle: "Your apps. Each keeps the pods (running copies) you ask for.",
                                term: .deployment)
                LazyVGrid(columns: Self.grid, spacing: DS.Spacing.l) {
                    ForEach(model.workloads) { workload in
                        WorkloadCard(workload: workload, model: model, nodeAddress: cluster.controlPlane?.address,
                                     showNamespace: model.namespace == nil,
                                     onPod: { openPod = $0 }, onDelete: { pendingDelete = workload },
                                     onEdit: { edit("\(workload.kind.resource)/\(workload.name)", workload.namespace, model) },
                                     onLoad: { image in Task { await clusters.load(image, into: name); await model.refresh() } })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func services(_ cluster: Cluster, _ model: ClusterModel) -> some View {
        if !model.services.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ExplainedHeader(title: "Services", subtitle: "Stable addresses in front of apps' pods: how apps, and you, reach them.",
                                term: .service)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: DS.Spacing.m, alignment: .top)],
                          spacing: DS.Spacing.m) {
                    ForEach(model.services) { service in
                        ServiceCard(service: service, nodeAddress: cluster.controlPlane?.address,
                                    showNamespace: model.namespace == nil,
                                    problems: model.portProblems[service.id] ?? [],
                                    onFix: { problem in Task { await model.fix(problem) } })
                            .contextMenu {
                                Button("Edit YAML…") { edit("service/\(service.name)", service.namespace, model) }
                                Button("Delete Service", role: .destructive) { pendingServiceDelete = service }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func loosePods(_ model: ClusterModel) -> some View {
        if !model.loosePods.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ExplainedHeader(title: "Pods on their own", subtitle: "Started directly, not by a workload: nothing restarts them if they stop.",
                                term: .pod)
                FlowLayout(spacing: DS.Spacing.s) {
                    ForEach(model.loosePods) { pod in
                        Button { openPod = pod } label: { PodChip(pod: pod, showNamespace: model.namespace == nil) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pod \(pod.name)")
                            .accessibilityValue(pod.reason ?? pod.phase)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A service port that leads nowhere, and the fix.
private struct PortProblemBanner: View {
    let problem: KubePortProblem
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(problem.displayMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(Tone.critical.text)
                .fixedSize(horizontal: false, vertical: true)
            if let port = problem.suggested, !problem.loopbackOnly {
                Button("Send to port \(String(port))", action: onFix)
                    .controlSize(.small)
                    .help("Point the service's target port at \(String(port)), where the pods listen")
            }
        }
        .padding(DS.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(Tone.critical.background))
    }
}

private struct ApplyText: Identifiable {
    let text: String
    var id: String { text }
}

// MARK: - Workload

private struct WorkloadCard: View {
    let workload: KubeWorkload
    let model: ClusterModel
    let nodeAddress: String?
    let showNamespace: Bool
    let onPod: (KubePod) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onLoad: (String) -> Void
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    private var tone: Tone {
        if workload.pods.contains(where: { $0.health == .failing }) { return .critical }
        if workload.desired == 0 { return .neutral }
        return workload.ready >= workload.desired ? .positive : .warning
    }

    private var icon: String {
        switch workload.kind {
        case .deployment: return "square.stack.3d.forward.dottedline"
        case .statefulSet: return "cylinder.split.1x2"
        case .daemonSet: return "circle.grid.cross"
        }
    }

    var body: some View {
        let busy = model.isBusy(workload.id)
        let trouble = workload.pods.first { $0.health == .failing } ?? workload.pods.first { $0.reason == "Unschedulable" }
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Image(systemName: icon).foregroundStyle(tone.fill)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workload.name).font(.headline).lineLimit(1)
                    HStack(spacing: DS.Spacing.xs) {
                        Text(verbatim: showNamespace ? "\(workload.kind.title) · \(workload.namespace)" : workload.kind.title)
                            .font(.caption).foregroundStyle(.secondary)
                        TermInfo(workload.kind == .deployment ? .deployment : workload.kind == .statefulSet ? .statefulSet : .daemonSet)
                            .controlSize(.mini)
                    }
                }
                Spacer()
                StatusPill(tone: tone, label: "\(workload.ready)/\(workload.desired) ready")
            }
            ForEach(workload.images, id: \.self) { image in
                Label(image, systemImage: "shippingbox").font(DS.Font.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            // One mark per pod, by state; click for its logs and a shell.
            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(workload.pods) { pod in
                    Button { onPod(pod) } label: { PodChip(pod: pod, showNamespace: false, compact: true) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pod \(pod.name)")
                        .accessibilityValue(pod.reason ?? pod.phase)
                }
                if workload.pods.isEmpty {
                    Text("No pods").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trouble, let advice = PodAdvice.text(for: trouble) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Label(trouble.reason ?? String(localized: "Trouble"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Tone.critical.text)
                    Text(advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let image = PodAdvice.loadable(trouble, local: app.model.images.map(\.reference)) {
                        Button("Load \(image) into the cluster") { onLoad(image) }.controlSize(.small)
                    }
                }
                .padding(DS.Spacing.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(Tone.critical.background))
            }
            let reach = model.services(for: workload)
            ForEach(reach.flatMap { model.portProblems[$0.id] ?? [] }) { problem in
                PortProblemBanner(problem: problem) { Task { await model.fix(problem) } }
            }
            if !reach.isEmpty {
                FlowLayout(spacing: DS.Spacing.xs) {
                    ForEach(reach) { service in
                        ForEach(service.ports, id: \.self) { port in
                            if let nodePort = port.nodePort, let nodeAddress,
                               let url = URL(string: "http://\(nodeAddress):\(nodePort)") {
                                Button { openURL(url) } label: {
                                    Label(String("\(service.name):\(port.port) → \(nodeAddress):\(nodePort)"), systemImage: "arrow.up.right")
                                        .font(DS.Font.monoSmall)
                                }
                                .buttonStyle(.borderless)
                                .help("Open through the node port")
                            } else {
                                Text(verbatim: "\(service.name):\(port.port)").font(DS.Font.monoSmall).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(DS.subtleFill))
                                    .help("Inside the cluster only (ClusterIP)")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: DS.Spacing.s) {
                if workload.canScale {
                    Text("Copies").foregroundStyle(.secondary)
                    TermInfo(.replicas)
                    Button { Task { await model.scale(workload, to: workload.desired - 1) } } label: { Image(systemName: "minus") }
                        .disabled(busy || workload.desired == 0)
                        .help("One pod fewer")
                    Text(verbatim: "\(workload.desired)").monospacedDigit().frame(minWidth: 18)
                    Button { Task { await model.scale(workload, to: workload.desired + 1) } } label: { Image(systemName: "plus") }
                        .disabled(busy)
                        .help("One pod more")
                } else {
                    Text("One pod per node").foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button { Task { await model.restart(workload) } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    .disabled(busy)
                    .help(Glossary.rolloutRestart.text)
                Menu {
                    Button("Edit YAML…", action: onEdit)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .font(.callout)
            .controlSize(.small)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.separator))
    }
}

/// A pod as a small chip: its state color, name, restarts.
private struct PodChip: View {
    let pod: KubePod
    let showNamespace: Bool
    var compact = false

    private var tone: Tone {
        switch pod.health {
        case .ok: return .positive
        case .starting: return .warning
        case .failing: return .critical
        case .done: return .neutral
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            StatusDot(tone: tone, size: 7)
            Text(compact ? String(pod.name.split(separator: "-").last ?? Substring(pod.name)) : pod.name)
                .font(DS.Font.monoSmall)
            if pod.restarts > 0 {
                Text(verbatim: "↻\(pod.restarts)").font(.caption2).foregroundStyle(Tone.warning.text)
            }
            if showNamespace { Text(pod.namespace).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, DS.Spacing.s).padding(.vertical, 3)
        .background(Capsule().fill(tone.background))
        .contentShape(Capsule())
        .help(pod.restarts > 0
              ? "\(pod.name): \(pod.reason ?? pod.phase), restarted \(pod.restarts)× — click for logs and a shell"
              : "\(pod.name): \(pod.reason ?? pod.phase) — click for logs and a shell")
    }
}

private struct ServiceCard: View {
    let service: KubeService
    let nodeAddress: String?
    let showNamespace: Bool
    var problems: [KubePortProblem] = []
    var onFix: (KubePortProblem) -> Void = { _ in }
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                Text(service.name).fontWeight(.semibold)
                if showNamespace { Text(service.namespace).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(service.type).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(service.ports, id: \.self) { port in
                HStack(spacing: DS.Spacing.xs) {
                    Text(verbatim: "\(port.port)/\(port.proto.lowercased()) → \(port.target)").font(DS.Font.monoSmall)
                    Spacer()
                    if let nodePort = port.nodePort, let nodeAddress,
                       let url = URL(string: "http://\(nodeAddress):\(nodePort)") {
                        Button { openURL(url) } label: {
                            Label(String("\(nodeAddress):\(nodePort)"), systemImage: "arrow.up.right").font(DS.Font.monoSmall)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if service.type == "ClusterIP" {
                Text("Reachable inside the cluster as \(service.name).\(service.namespace)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(problems) { problem in PortProblemBanner(problem: problem) { onFix(problem) } }
        }
        .padding(DS.Spacing.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.separator))
    }
}

// MARK: - Pod

/// A pod: why it is in its state, its logs, a shell.
private struct PodSheet: View {
    let pod: KubePod
    let model: ClusterModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "logs"
    @State private var confirmDelete = false

    /// A workload replaces it; a pod on its own is gone for good.
    private var owned: Bool { !(model.snapshot?.loosePods.contains(pod) ?? false) }

    private var tone: Tone { pod.health == .ok ? .positive : pod.health == .failing ? .critical : .warning }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.xs) {
                Text("Pod").font(.title3.weight(.semibold))
                TermInfo(.pod)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                StatusDot(tone: tone)
                Text(pod.name).font(DS.Font.mono.weight(.semibold)).textSelection(.enabled)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if pod.health != .ok { StatusPill(tone: tone, label: pod.reason ?? pod.phase) }
            }
            Picker("View", selection: $tab) {
                Text("Logs").tag("logs")
                Text("Shell").tag("terminal")
                Text("Details").tag("details")
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()
            Group {
                switch tab {
                case "logs":
                    LogsTab(id: pod.name, lines: { [stream = CLIStream(binaryPath: Settings.shared.binaryPath),
                                                    arguments = model.client.logArguments(pod)] in
                        stream.lines(arguments, mergeStderr: true)
                    })
                case "terminal":
                    VStack(spacing: 0) {
                        HStack {
                            Text(verbatim: "kubectl exec -it \(pod.name) -n \(pod.namespace) -- sh")
                                .font(DS.Font.monoSmall).foregroundStyle(.white.opacity(0.6)).textSelection(.enabled)
                            Spacer()
                            OpenTerminalWindowButton(target: TerminalTarget(
                                title: pod.name, command: "kubectl exec -it \(pod.name) -n \(pod.namespace) -- sh",
                                arguments: model.client.shellArguments(pod)))
                                .controlSize(.small)
                        }
                        .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.xs)
                        ContainerTerminalView(binaryPath: Settings.shared.binaryPath,
                                              arguments: model.client.shellArguments(pod), dark: true, onExit: { _ in })
                    }
                    .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                default:
                    details
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.separator.opacity(0.6)))
            HStack(spacing: DS.Spacing.s) {
                Button("Delete Pod") { confirmDelete = true }.buttonStyle(.automatic)
                Text(owned ? "A new one starts automatically" : "Nothing replaces it")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Spacing.l)
        .frame(minWidth: 720, idealWidth: 860, minHeight: 520, idealHeight: 600)
        .confirmationDialog("Delete pod “\(pod.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Pod", role: .destructive) { Task { await model.delete(pod); dismiss() } }
        } message: {
            Text(pod.namespace.isEmpty ? "" : "If a workload owns it, a fresh pod replaces it; a pod on its own is gone for good.")
        }
    }
}

extension PodSheet {
    /// "on worker-1 · 0 restarts".
    var subtitle: String {
        [pod.node.map { String(localized: "on \($0)", comment: "Pod: the node it runs on") }, String(localized: "\(pod.restarts) restarts")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                if let advice = PodAdvice.text(for: pod) {
                    Label(advice, systemImage: pod.health == .failing ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(pod.health == .failing ? Tone.critical.text : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.l, verticalSpacing: DS.Spacing.s) {
                    row("Namespace", pod.namespace)
                    row("Node", pod.node ?? "—")
                    row("Phase", pod.reason.map { "\(pod.phase) · \($0)" } ?? pod.phase)
                    row("Containers", pod.containers.joined(separator: ", "))
                    row("Images", pod.images.joined(separator: "\n"))
                    row("Labels", pod.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                }
            }
            .font(.callout)
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value.isEmpty ? "—" : value).font(DS.Font.monoSmall).textSelection(.enabled)
        }
    }
}

// MARK: - Connect, load image

private struct ConnectPopover: View {
    let cluster: String
    let kubeconfig: String?
    let clusters: ClustersModel
    @State private var added = false
    @State private var error: String?

    private var context: String { kubeconfig == nil ? cluster : Kubeconfig.contextName(for: cluster) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Use \(cluster) from your own terminal").font(.headline)
            Text(kubeconfig == nil || added
                 ? "Its context is in ~/.kube/config as \(context)."
                 : "Adds the cluster to ~/.kube/config as context \(context). Your current context stays as it is.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text(verbatim: "kubectl --context \(context) get pods")
                    .font(DS.Font.monoSmall).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                CopyButton(value: "kubectl --context \(context) get pods")
            }
            .padding(DS.Spacing.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.subtleFill))
            if let kubeconfig, !added {
                Button {
                    do {
                        try Kubeconfig.add(cluster, from: kubeconfig)
                        added = true
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                } label: {
                    Text("Add to kubeconfig").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if added {
                Label("Added. Helm, k9s and Lens see it too.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(Tone.positive.text)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Tone.critical.text)
            }
            Button("Save a Separate kubeconfig File…") { save() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(DS.Spacing.l)
        .frame(width: 360)
        .onAppear { added = kubeconfig != nil && Kubeconfig.isAdded(cluster) }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(cluster).kubeconfig"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await clusters.writeConfig(cluster, to: url.path) }
    }
}

private struct LoadImageSheet: View {
    let cluster: String
    let clusters: ClustersModel
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var image = ""
    @State private var loading = false

    private var images: [String] { app.model.images.filter { !$0.isSystem }.map(\.reference).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Load an Image into \(cluster)").font(.headline)
            Picker("Image", selection: $image) {
                Text("Choose an image").tag("")
                ForEach(images, id: \.self) { Text($0).tag($0) }
            }
            Text("Pods can then use it without a registry. Refer to it by this name with imagePullPolicy: IfNotPresent (or Never); with :latest Kubernetes would try to pull it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = clusters.error, !loading {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Tone.critical.text)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(loading)
                Button(loading ? "Loading…" : "Load") {
                    Task {
                        loading = true
                        await clusters.load(image, into: cluster)
                        loading = false
                        if clusters.error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(image.isEmpty || loading)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 480)
    }
}
