import SwiftUI
import AppKit
import ContainerKit

/// The menu-bar popover: engine state, what's running and how to reach it,
/// and quick actions. Shares `AppState` with the main window.
public struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var busy: Set<String> = []
    @State private var isStarting = false
    @State private var stats = LiveStats()
    @State private var clusters: [Cluster] = []
    @State private var isVisible = false

    public init() {}

    private var containers: [Container] { app.model.containers.filter { !$0.isSystem } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch app.model.snapshot.service {
            case .running:
                workloads
                if let error = app.model.snapshot.error(for: .containers) {
                    NoticeBanner(tone: .warning, title: "Couldn't refresh containers", message: error.localizedDescription)
                        .padding(DS.Spacing.s)
                }
            case .stopped:
                startEngine
            case .failed(let error):
                NoticeBanner(tone: .warning, title: "Status unavailable", message: error.localizedDescription)
                    .padding(DS.Spacing.s)
            case .unknown:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(DS.Spacing.l)
            }
            Divider()
            if case .available(let appcast) = app.appUpdater.phase {
                Button { openWindow(id: "about"); NSApplication.shared.activate() } label: {
                    Label("Update to Irekobox \(appcast.version)…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.accent)
                .padding(.horizontal, DS.Spacing.m)
                .padding(.top, DS.Spacing.m)
            }
            footer
        }
        .frame(width: 340)
        .tint(DS.accent)
        .errorToast(Binding(get: { app.actionError }, set: { app.actionError = $0 }))
        // MenuBarExtra(.window) retains its content when ordered out. Its
        // tasks must follow the AppKit window, not just SwiftUI appearance.
        .background(MenuBarVisibility { isVisible = $0 })
        .task(id: isVisible) {
            guard isVisible else { return }
            await app.model.observe([.containers])
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            let stats = self.stats
            await stats.run(engine: app.engine, interval: .seconds(3)) { [app] in
                app.model.containers.filter { $0.state.isRunning && !$0.isSystem }.map(\.id)
            }
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            let repository = ClusterRepository(cli: app.cli, stream: CLIStream(binaryPath: Settings.shared.binaryPath))
            if let list = try? await repository.list(), !Task.isCancelled { clusters = list }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: DS.Spacing.s) {
            StatusDot(tone: engineTone, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(engineTitle).font(.callout.weight(.semibold))
                Text(engineSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.servicesRunning {
                Text(usageText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                Button("Find Anything…") { openMain(); app.showPalette = true }
                    .disabled(!app.servicesRunning)
                Button("Refresh") { app.requestRefresh() }
                SettingsLink { Text("Settings…") }
                Divider()
                Button("Quit Irekobox") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
        }
        .padding(DS.Spacing.m)
    }

    private var engineTone: Tone {
        switch app.model.snapshot.service {
        case .running: return .positive
        case .stopped: return .critical
        case .failed: return .warning
        case .unknown: return .inactive
        }
    }

    private var engineTitle: String {
        switch app.model.snapshot.service {
        case .running: return String(localized: "Engine running")
        case .stopped: return String(localized: "Engine stopped")
        case .failed: return String(localized: "Status unavailable")
        case .unknown: return String(localized: "Connecting…")
        }
    }

    /// "CPU 23% · 3.1 GB" across running containers.
    private var usageText: String {
        let series = stats.series.values
        let cpu = series.compactMap(\.latestCPU).reduce(0, +)
        let memory = series.map(\.memoryUsage).reduce(0, +)
        return String(localized: "CPU \(Int(cpu.rounded()))% · \(Format.memory(memory))")
    }

    private var engineSubtitle: String {
        let running = containers.filter { $0.state.isRunning }.count
        guard app.servicesRunning else { return "container \(app.systemStatus?.apiServerVersion ?? "")" }
        return String(localized: "\(running) running · \(containers.count) total")
    }

    private var startEngine: some View {
        Button {
            Task {
                isStarting = true
                await app.startServices()
                isStarting = false
            }
        } label: {
            HStack {
                if isStarting { ProgressView().controlSize(.small) }
                Text(isStarting ? "Starting…" : "Start Engine")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isStarting)
        .padding(DS.Spacing.m)
    }

    /// What shows as one line: a compose project, a cluster, a machine, a container.
    private enum Item: Identifiable {
        case project(String, [Container])
        case cluster(Cluster)
        case machine(Container)
        case container(Container)

        var id: String {
            switch self {
            case .project(let name, _): "p:" + name
            case .cluster(let cluster): "k:" + cluster.name
            case .machine(let container): "m:" + container.id
            case .container(let container): "c:" + container.id
            }
        }
    }

    private var items: [Item] {
        let nodes = Set(clusters.flatMap { $0.nodes.map(\.name) })
        let user = app.model.containers.filter { !$0.isSystem || $0.isMachine }.filter { !nodes.contains($0.id) }
        var items: [Item] = []
        for group in ContainerList.group(user.filter { !$0.isMachine }) {
            if let project = group.project {
                items.append(.project(project, group.containers))
            } else {
                items += group.containers.map(Item.container)
            }
        }
        items += clusters.map(Item.cluster)
        items += user.filter(\.isMachine).map(Item.machine)
        return items
    }

    @ViewBuilder
    private var workloads: some View {
        if items.isEmpty {
            Text("No containers yet.").font(.callout).foregroundStyle(.secondary).padding(DS.Spacing.m)
        } else {
            ScrollView {
                VStack(spacing: DS.Spacing.s) {
                    ForEach(items) { item($0) }
                }
                .padding(DS.Spacing.m)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func item(_ item: Item) -> some View {
        switch item {
        case .project(let name, let containers):
            let running = containers.filter { $0.state.isRunning }
            card(title: name,
                 detail: running.isEmpty ? String(localized: "stopped") : String(localized: "\(running.count) of \(containers.count)"),
                 tone: running.isEmpty ? .neutral : running.count == containers.count ? .positive : .warning,
                 port: running.lazy.flatMap { ContainerPresentation($0).ports }.first,
                 busyID: "p:" + name,
                 action: running.isEmpty ? .start : .stop,
                 perform: { await setRunning(!running.isEmpty ? false : true, containers, id: "p:" + name) },
                 open: { app.revealProject = name; app.section = .compose; openMain() })
        case .cluster(let cluster):
            card(title: cluster.name,
                 detail: cluster.isRunning ? String(localized: "Kubernetes · \(cluster.nodes.count) nodes") : String(localized: "stopped"),
                 tone: cluster.isRunning ? .positive : .neutral, port: nil, busyID: "k:" + cluster.name,
                 action: .open, perform: { app.revealCluster = cluster.name; app.section = .kubernetes; openMain() },
                 open: { app.revealCluster = cluster.name; app.section = .kubernetes; openMain() })
        case .machine(let container):
            card(title: container.machineName ?? container.id, detail: container.state.isRunning ? String(localized: "machine") : String(localized: "machine · stopped"),
                 tone: container.state.isRunning ? .positive : .neutral, port: nil, busyID: container.id,
                 action: container.state.isRunning ? .stop : .start,
                 perform: { await setRunning(!container.state.isRunning, [container], id: container.id) },
                 open: { app.section = .machines; openMain() })
        case .container(let container):
            let presentation = ContainerPresentation(container)
            card(title: container.id, detail: container.state.isRunning ? container.imageShortName : String(localized: "stopped"),
                 tone: presentation.tone, port: container.state.isRunning ? presentation.ports.first : nil, busyID: container.id,
                 action: container.state.isRunning ? .stop : .start,
                 perform: { await setRunning(!container.state.isRunning, [container], id: container.id) },
                 open: { reveal(container) })
        }
    }

    private enum CardAction { case start, stop, open }

    private func card(title: String, detail: String, tone: Tone, port: PortLink?, busyID: String,
                      action: CardAction, perform: @escaping () async -> Void, open: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Button(action: open) {
                HStack(spacing: DS.Spacing.s) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(tone == .positive ? Tone.positive.text : .secondary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Show in Irekobox")
            Spacer(minLength: DS.Spacing.xs)
            if let port, let url = port.url {
                Link(destination: url) {
                    Text(verbatim: ":\(String(port.hostPort)) ↗").font(DS.Font.monoSmall.weight(.semibold))
                }
                .help("Open \(url.absoluteString)")
            }
            if busy.contains(busyID) {
                ProgressView().controlSize(.mini).frame(width: 24)
            } else {
                Button { Task { await perform() } } label: {
                    Image(systemName: action == .stop ? "stop.fill" : action == .start ? "play.fill" : "chevron.right")
                        .font(.caption)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.raised))
                }
                .buttonStyle(.plain)
                .help(action == .stop ? "Stop" : action == .start ? "Start" : "Open")
                .accessibilityLabel(action == .stop ? "Stop \(title)" : action == .start ? "Start \(title)" : "Open \(title)")
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2).fill(DS.subtleFill.opacity(0.8)))
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.s) {
            Button { openMain(); app.requestRun() } label: { Text("Run Container…").frame(maxWidth: .infinity) }
                .disabled(!app.servicesRunning)
            Button { openMain() } label: { Text("Open Irekobox").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.automatic)
        .padding(DS.Spacing.m)
    }

    private func menuButton(_ title: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 5)
    }

    // MARK: - Actions

    /// Start or stop each of `containers` (a project, or one container).
    private func setRunning(_ run: Bool, _ containers: [Container], id: String) async {
        busy.insert(id)
        defer { busy.remove(id) }
        let ids = containers.filter { $0.state.isRunning != run }.map(\.id)
        await app.perform {
            app.noteHandAction(stopped: !run, ids)
            for container in ids {
                if run { try await app.engine.startContainer(container) } else { try await app.engine.stopContainer(container) }
            }
        }
    }

    private func reveal(_ container: Container) {
        app.section = .containers
        app.revealContainer = container.id
        openMain()
    }

    /// Bring the main window forward, opening one if the last was closed.
    private func openMain() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let mainWindows = NSApplication.shared.windows.filter {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain
        }
        guard !mainWindows.isEmpty else {
            openWindow(id: "main")
            return
        }
        for window in mainWindows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Bridges the retained popover window's visibility without a polling timer.
private struct MenuBarVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = changed
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        let changed = view.changed
        view.changed = { _ in }
        Task { @MainActor in changed(false) }
    }

    final class VisibilityView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var lastVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                             NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                           name: name, object: window)
                }
            }
            visibilityChanged()
        }

        @objc private func visibilityChanged() {
            // Defer publication outside the NSViewRepresentable update pass.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
                guard visible != lastVisible else { return }
                lastVisible = visible
                changed(visible)
            }
        }
    }
}
