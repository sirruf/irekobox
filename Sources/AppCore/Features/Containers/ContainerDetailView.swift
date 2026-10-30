import SwiftUI
import ContainerKit

/// Detail screen for a single container with Overview / Logs / Stats tabs.
struct ContainerDetailView: View {
    @Environment(AppState.self) private var app
    let container: Container

    /// Opens on Overview; a one-off request (the card's terminal button)
    /// can pick another tab for this opening only.
    @AppStorage("containerDetailTab") private var requestedTab: DetailTab = .overview
    @State private var tab: DetailTab = .overview
    @State private var editing = false
    @State private var stats = LiveStats()
    @State private var busy = false

    enum DetailTab: String, Hashable { case overview, logs, stats, files, console }

    /// The latest state from the shared store, falling back to the value we
    /// navigated with (e.g. right after the container was removed).
    private var current: Container {
        app.model.containers.first { $0.id == container.id } ?? container
    }

    /// The terminal is kept alive across tab switches once opened.
    @State private var consoleOpened = false

    var body: some View {
        ZStack {
            switch tab {
            case .overview:
                ContainerOverview(container: current, stats: stats.series[current.id], health: app.health[current.id],
                                  openLogs: { tab = .logs })
            case .logs: LogsTab(id: container.id)
            case .stats: StatsTab(container: current)
            case .files: FilesTab(container: current)
            case .console: Color.clear
            }
            if consoleOpened {
                ConsoleTab(container: current, isActive: tab == .console)
                    .opacity(tab == .console ? 1 : 0)
                    .allowsHitTesting(tab == .console)
                    .accessibilityHidden(tab != .console)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(container.id)
        .toolbar { toolbar }
        .onAppear {
            tab = requestedTab
            requestedTab = .overview
        }
        .onChange(of: tab, initial: true) { _, tab in if tab == .console { consoleOpened = true } }
        .task(id: container.id) { await app.model.observe([.containers]) }
        .task(id: container.id) {
            let stats = self.stats
            let id = container.id
            await stats.run(engine: app.engine) { [app] in
                app.model.containers.first { $0.id == id }?.state.isRunning == true ? [id] : []
            }
        }
        .sheet(isPresented: $editing) {
            EditContainerSheet(container: current) { Task { await app.model.refresh([.containers]) } }
                .environment(app)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: $tab) {
                Text("Overview").tag(DetailTab.overview)
                Text("Logs").tag(DetailTab.logs)
                Text("Stats").tag(DetailTab.stats)
                Text("Files").tag(DetailTab.files)
                Text("Terminal").tag(DetailTab.console)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("containerDetail.tabs")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Edit…") { editing = true }
                    .help("Change ports, volumes, environment and limits")
                    .accessibilityIdentifier("containerDetail.edit")
                if current.state.isRunning {
                    OpenTerminalWindowButton(target: TerminalTarget(
                        title: current.id, command: ConsoleShell.auto.displayCommand(containerID: current.id),
                        arguments: ConsoleShell.auto.arguments(containerID: current.id)),
                        title: "Terminal in New Window", systemImage: "macwindow.badge.plus")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("Edit, terminal window")
            .menuIndicator(.hidden)
            .accessibilityIdentifier("containerDetail.more")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) { actions }
    }

    @ViewBuilder
    private var actions: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if current.state.isRunning {
            Button {
                run {
                    app.noteHandAction(stopped: true, [current.id])
                    try await app.engine.stopContainer(current.id)
                    try await app.engine.startContainer(current.id)
                    app.noteHandAction(stopped: false, [current.id])
                }
            } label: { Text("Restart") }
                .help("Restart")
                .accessibilityIdentifier("containerDetail.restart")
            Button {
                run {
                    app.noteHandAction(stopped: true, [current.id])
                    try await app.engine.stopContainer(current.id)
                }
            } label: { Text("Stop") }
                .help("Stop")
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("containerDetail.stop")
        } else {
            Button {
                run {
                    app.noteHandAction(stopped: false, [current.id])
                    try await app.engine.startContainer(current.id)
                }
            } label: { Text("Start") }
            .buttonStyle(.borderedProminent)
            .help("Start")
            .accessibilityLabel("Start")
            .accessibilityIdentifier("containerDetail.start")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            busy = true
            await app.perform { try await action() }
            busy = false
        }
    }
}
