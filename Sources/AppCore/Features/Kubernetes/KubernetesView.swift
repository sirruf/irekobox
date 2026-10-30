import SwiftUI
import AppKit
import Observation
import ContainerKit

/// Local Kubernetes clusters (`container cluster`, experimental in 1.6).
@MainActor
@Observable
final class ClustersModel {
    private let repository: ClusterRepository
    private(set) var clusters: [Cluster] = []
    private(set) var loaded = false
    private(set) var busy: Set<String> = []
    private(set) var progress: [String] = []
    var error: String?
    var notice: String?

    init(cli: any ContainerCommanding, stream: CLIStream) {
        repository = ClusterRepository(cli: cli, stream: stream)
    }

    /// Cluster → the kubeconfig file its context went to (when not the
    /// default one), so deleting it leaves ~/.kube/config alone.
    private static let filesKey = "clusterKubeconfigs"
    private var files: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.filesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.filesKey) }
    }

    func kubeconfig(of name: String) -> String? { files[name] }

    func refresh() async {
        do {
            clusters = try await repository.list()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    func create(_ options: ClusterRepository.CreateOptions) async -> Bool {
        busy.insert(options.name)
        defer { busy.remove(options.name) }
        progress = []
        if let path = options.kubeconfig { files[options.name] = path }
        do {
            for try await line in repository.create(options) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { progress = Array((progress + [text]).suffix(6)) }
            }
            error = nil
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            await refresh()
            return false
        }
    }

    private func perform(_ name: String, _ action: () async throws -> Void) async {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func delete(_ name: String) async {
        let file = files[name]
        await perform(name) { try await repository.delete(name, kubeconfig: file) }
        if error == nil { files[name] = nil }
    }

    func load(_ image: String, into name: String) async {
        await perform(name) { try await repository.loadImage(image, into: name) }
        if error == nil { notice = String(localized: "\(image) is in \(name); use it with imagePullPolicy: Never.") }
    }

    func writeConfig(_ name: String, to path: String) async {
        await perform(name) { try await repository.writeConfig(name, to: path) }
        if error == nil { notice = String(localized: "Wrote \((path as NSString).abbreviatingWithTildeInPath).") }
    }
}

struct KubernetesView: View {
    @Environment(AppState.self) private var app
    @State private var model: ClustersModel?
    @State private var showCreate = false
    @State private var path: [String] = []
    /// What runs in each running cluster, for the cards (read once a minute).
    @State private var insides: [String: ClusterModel] = [:]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            // Empty states and loading sit on the canvas too, not on the window's white.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.canvas)
            .navigationTitle("Kubernetes")
            .navigationSubtitle("Local clusters for apps headed to Kubernetes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Cluster…") { showCreate = true }
                        .buttonStyle(.borderedProminent)
                        .help("Create a cluster")
                        .accessibilityIdentifier("kubernetes.new")
                }
            }
            .onChange(of: app.revealCluster, initial: true) { _, name in
                guard let name else { return }
                path = [name]
                app.revealCluster = nil
            }
            .navigationDestination(for: String.self) { name in
                if let model { ClusterView(name: name, clusters: model) { path.removeAll() } }
            }
        }
        .onAppear {
            if model == nil {
                model = ClustersModel(cli: app.cli, stream: CLIStream(binaryPath: Settings.shared.binaryPath))
            }
        }
        .task(id: model == nil) {
            guard let model else { return }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(isPresented: $showCreate) {
            if let model { NewClusterSheet(model: model) { path = [$0] } }
        }
        .task(id: model?.clusters.filter(\.isRunning).map(\.name) ?? []) {
            guard let model else { return }
            while !Task.isCancelled {
                for cluster in model.clusters where cluster.isRunning {
                    guard let node = cluster.controlPlane?.name else { continue }
                    let inside = insides[cluster.name] ?? ClusterModel(name: cluster.name, node: node, cli: app.cli)
                    await inside.refresh()
                    insides[cluster.name] = inside
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @ViewBuilder
    private func content(_ model: ClustersModel) -> some View {
        if model.loaded && model.clusters.isEmpty && model.busy.isEmpty {
            ContentUnavailableView {
                Label("No Clusters", systemImage: "helm")
            } description: {
                Text("A local Kubernetes cluster runs its nodes as containers. It boots in about a minute; then you see what runs in it here, and kubectl reaches it too.")
            } actions: {
                Button("New Cluster…") { showCreate = true }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: DS.Spacing.l, alignment: .top)],
                          spacing: DS.Spacing.l) {
                    ForEach(model.clusters) { cluster in
                        ClusterCard(cluster: cluster, busy: model.busy.contains(cluster.name),
                                    inside: insides[cluster.name]) { path.append(cluster.name) }
                    }
                }
                .padding(DS.Spacing.l)
                LearnNote("**New to Kubernetes?** A cluster is a group of machines that runs your app in copies and replaces broken ones. Here each node is a container. Open a cluster, then use *Run an App* — every step shows what it means.")
                    .padding(.horizontal, DS.Spacing.l)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
                        .font(.callout).padding(.horizontal, DS.Spacing.l)
                }
            }
            .background(DS.canvas)
        }
    }
}

/// A cluster in the list: its state and nodes. Clicking opens it.
private struct ClusterCard: View {
    let cluster: Cluster
    let busy: Bool
    /// What runs in it, once read.
    let inside: ClusterModel?
    let open: () -> Void
    @State private var hovering = false

    /// Apps whose pods keep failing, then services sending to a port
    /// nothing listens on: one named, or how many.
    private func attention(_ problems: [KubePortProblem]) -> String? {
        let failing = inside?.workloads.filter { $0.pods.contains { $0.health == .failing } }.map(\.name) ?? []
        let count = failing.count + problems.count
        if count > 1 { return String(localized: "\(count) things need attention") }
        if let name = failing.first { return String(localized: "1 thing needs attention: \(name) keeps failing") }
        if let problem = problems.first {
            return String(localized: "1 thing needs attention: service \(problem.service.name) sends to a port nothing listens on")
        }
        return nil
    }

    var body: some View {
        let pods = inside.map { $0.workloads.flatMap(\.pods) + $0.loosePods }
        let problems = inside?.portProblems.values.flatMap { $0 } ?? []
        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                StatusDot(tone: cluster.isRunning ? .positive : .inactive)
                Text(cluster.name).font(.title3.weight(.semibold))
                Text("Kubernetes").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(cluster.isRunning ? "Ready" : "Stopped").font(.callout)
                        .foregroundStyle(cluster.isRunning ? Tone.positive.text : .secondary)
                }
            }
            if cluster.isRunning {
                HStack(spacing: DS.Spacing.s) {
                    tile("Nodes", "\(cluster.nodes.count)")
                    tile("Apps", inside.map { "\($0.workloads.count)" } ?? "—")
                    tile("Pods", pods.map { "\($0.count)" } ?? "—")
                }
                if let attention = attention(problems) {
                    Text(attention).font(.callout).foregroundStyle(Tone.warning.text)
                }
            } else {
                Text("\(cluster.nodes.count) nodes · stopped with the engine")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .panel()
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .strokeBorder(DS.accent.opacity(hovering ? 0.6 : 0), lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kubernetes.cluster.\(cluster.name)")
        .cardAction(cornerRadius: DS.Radius.panel, open)
    }

    private func tile(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.s + 2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2).fill(DS.subtleFill))
    }
}

struct NewClusterSheet: View {
    let model: ClustersModel
    var onCreated: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = "dev"
    @State private var cpus = 2
    @State private var memory = "8G"
    @State private var workers = 0
    @State private var separateFile = true
    @State private var creating = false

    private var kubeconfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube/\(name).kubeconfig").path
    }

    private var taken: Bool { model.clusters.contains { $0.name == name } }
    private var validName: Bool { !name.isEmpty && LocalDomain.label(name) == name }

    /// The two sizes on the cards; Custom keeps whatever was set below.
    private enum Size { case tiny, production, custom }
    @State private var size: Size = .tiny
    @State private var showOptions = false

    private func sizeCard(_ which: Size, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        let chosen = size == which
        return Button { pick(which) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(chosen ? DS.accent : DS.separator.opacity(0.6), lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func pick(_ size: Size) {
        self.size = size
        switch size {
        case .tiny: workers = 0; memory = "2G"; cpus = 2
        case .production: workers = 2; memory = "2G"; cpus = 2
        case .custom: break
        }
    }

    private var summary: String {
        let gigabytes = (Int(memory.dropLast()) ?? 0) * (workers + 1)
        if workers == 0 {
            return String(localized: "1 node · \(gigabytes) GB · \(cpus) CPUs each · about a minute to start")
        }
        return String(localized: "1 + \(workers) nodes · \(gigabytes) GB · \(cpus) CPUs each · about 2 minutes to start")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("New Cluster").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Name").font(.callout.weight(.medium))
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).labelsHidden()
                Group {
                    if !validName {
                        Text("Use lowercase letters, digits and hyphens.").foregroundStyle(Tone.warning.text)
                    } else if taken {
                        Text("A cluster with this name exists.").foregroundStyle(Tone.warning.text)
                    } else {
                        Label("available", systemImage: "checkmark").foregroundStyle(Tone.positive.text)
                    }
                }
                .font(.caption)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("Size").font(.callout.weight(.semibold))
                HStack(spacing: DS.Spacing.s) {
                    sizeCard(.tiny, "Tiny", "1 node · 2 GB")
                    sizeCard(.production, "Like production", "1 + 2 nodes · 6 GB")
                }
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Custom Size and kubeconfig", isExpanded: $showOptions) {
                Form {
                    Stepper("CPUs per node: \(cpus)", value: Binding(get: { cpus }, set: { cpus = $0; size = .custom }),
                            in: 1...ProcessInfo.processInfo.activeProcessorCount)
                    Picker("Memory per node", selection: Binding(get: { memory }, set: { memory = $0; size = .custom })) {
                        ForEach(["2G", "4G", "8G", "16G"], id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Worker nodes: \(workers)", value: Binding(get: { workers }, set: { workers = $0; size = .custom }), in: 0...3)
                    Picker("kubectl context", selection: $separateFile) {
                        Text("In its own file").tag(true)
                        Text("Added to ~/.kube/config").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }
                Text(separateFile
                     ? "Written to \((kubeconfigPath as NSString).abbreviatingWithTildeInPath); Connect kubectl adds it to ~/.kube/config when you want."
                     : "Added to ~/.kube/config as context \(name); kubectl may switch to it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if creating {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(model.progress, id: \.self) { Text($0).font(DS.Font.monoSmall).lineLimit(1) }
                }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.automatic).keyboardShortcut(.cancelAction).disabled(creating)
                Button(creating ? "Creating…" : "Create Cluster") {
                    Task {
                        creating = true
                        try? FileManager.default.createDirectory(
                            at: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube"),
                            withIntermediateDirectories: true)
                        let ok = await model.create(.init(name: name, cpus: cpus, memory: memory, workers: workers,
                                                          kubeconfig: separateFile ? kubeconfigPath : nil))
                        creating = false
                        if ok { onCreated(name); dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(creating || !validName || taken)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440)
        .onAppear {
            pick(.tiny)
            // "dev", or the first "dev-2", "dev-3"… nobody has.
            let names = Set(model.clusters.map(\.name))
            name = ([name] + (2...20).map { "dev-\($0)" }).first { !names.contains($0) } ?? name
        }
    }
}
