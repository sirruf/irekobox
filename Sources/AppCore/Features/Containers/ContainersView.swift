import SwiftUI
import ContainerKit

/// Containers: cards or a sortable table with an inspector, grouped by
/// compose project, with live CPU/memory. Either way a click selects (⌘ and
/// ⇧ as in Finder), double-click or Return opens the container's page, and
/// the selection can be started, stopped or deleted together.
struct ContainersView: View {
    @Environment(AppState.self) private var app
    @State private var model: ContainersViewModel?
    @State private var stats = LiveStats()
    @State private var selection = CardSelection()
    @State private var search = ""
    @State private var stateFilter: ContainerList.StateFilter = .all
    @State private var sortOrder: [KeyPathComparator<ContainerRow>] = [.init(\.name)]
    @State private var path: [String] = []
    @State private var pendingDelete: Set<String> = []
    @AppStorage("showSystemContainers") private var showSystem = false
    @AppStorage("containersInspectorShown") private var inspectorShown = true
    @AppStorage("containersLayout") private var layout: ContainersLayout = .cards
    @AppStorage("containerDetailTab") private var detailTab: ContainerDetailView.DetailTab = .overview
    @FocusState private var tableFocused: Bool
    /// The inspector shows the image, so its column steps aside while it's open.
    @State private var columns = TableColumnCustomization<ContainerRow>()

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        // Empty states and loading sit on the canvas too, not on the window's white.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.canvas)
        .onAppear {
            if model == nil { model = ContainersViewModel(engine: app.engine, model: app.model) { [app] stopped, ids in app.noteHandAction(stopped: stopped, ids) } }
        }
        .task { await app.model.observe([.containers]) }
        .onChange(of: app.revealContainer, initial: true) { _, name in
            guard let name else { return }
            selection.set([name])
            // Keep going from the keyboard: Return opens it, arrows move on.
            tableFocused = true
            app.revealContainer = nil
        }
        .onChange(of: app.openContainerPage, initial: true) { _, request in
            guard let request else { return }
            detailTab = request.tab
            path = [request.id]
            app.openContainerPage = nil
        }
        .task(id: sampledIDs) {
            let ids = sampledIDs
            await stats.run(engine: app.engine) { ids }
        }
    }

    // MARK: - Data

    /// Match the displayed list, including search, state and system filters.
    private var sampledIDs: [String] {
        guard path.isEmpty else { return [] }
        return ContainerList.filter(model?.containers ?? [], search: search, state: stateFilter, includeSystem: showSystem)
            .filter { $0.state.isRunning }.map(\.id).sorted()
    }

    private func rows(_ model: ContainersViewModel) -> [ContainerRow] {
        ContainerList.filter(model.containers, search: search, state: stateFilter, includeSystem: showSystem)
            .map { ContainerRow(container: $0, stats: stats.series[$0.id]) }
            .sorted(using: sortOrder)
    }

    private func groups(_ rows: [ContainerRow]) -> [(group: ContainerList.Group, rows: [ContainerRow])] {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ContainerList.group(rows.map(\.container)).map { group in
            (group, group.containers.compactMap { byID[$0.id] })
        }
    }

    private func selected(_ model: ContainersViewModel) -> [Container] {
        model.containers.filter { selection.contains($0.id) }
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(_ model: ContainersViewModel) -> some View {
        let rows = rows(model)
        NavigationStack(path: $path) {
            Group {
                if rows.isEmpty && !model.isLoading {
                    emptyState(model)
                } else if layout == .cards {
                    cards(model, rows: rows)
                } else {
                    table(model, rows: rows)
                }
            }
            .navigationTitle("Containers")
            .navigationSubtitle("Apps running in isolation, each started from an image")
            .navigationDestination(for: String.self) { id in
                if let container = model.containers.first(where: { $0.id == id }) {
                    ContainerDetailView(container: container)
                } else {
                    ContentUnavailableView("Container Deleted", systemImage: "shippingbox",
                                           description: Text("“\(id)” no longer exists."))
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Name, image, port, project")
            .toolbar { toolbar(model) }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer(model) }
            .inspector(isPresented: Binding(get: { layout == .table && inspectorShown && !selection.isEmpty },
                                            set: { if !$0 { inspectorShown = false } })) {
                inspector(model)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                                  set: { if !$0 { pendingDelete = [] } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let ids = pendingDelete
                    pendingDelete = []
                    selection.set(selection.ids.subtracting(ids))
                    Task { await model.delete(ids) }
                }
                Button("Cancel", role: .cancel) { pendingDelete = [] }
            } message: {
                Text(deleteMessage(model))
            }
        }
    }

    private func cards(_ model: ContainersViewModel, rows: [ContainerRow]) -> some View {
        let groups = groups(rows)
        let updated = Set(app.model.images.filter { app.imageUpdates.update(for: $0) }.map(\.reference))
        let order = groups.flatMap { $0.rows.map(\.id) }
        return SelectionScroll(selection: $selection, all: order, onDelete: { pendingDelete = selection.ids }) {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.l + DS.Spacing.xs + 2) {
                ForEach(groups, id: \.group.id) { entry in
                    VStack(alignment: .leading, spacing: DS.Spacing.m) {
                        groupHeader(entry.group)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 440), spacing: DS.Spacing.m + 2)],
                                  spacing: DS.Spacing.m + 2) {
                            ForEach(entry.rows) { row in
                                ContainerCard(
                                    row: row, health: app.health[row.id], busy: model.busyIDs.contains(row.id),
                                    inProject: entry.group.project != nil,
                                    updateAvailable: updated.contains(row.container.configuration.image.reference),
                                    onTerminal: { detailTab = .console; path.append(row.id) },
                                    onStart: { Task { await model.start([row.id]) } },
                                    onStop: { Task { await model.stop([row.id]) } })
                                .selectableCard(row.id, in: $selection, order: order, cornerRadius: DS.Radius.panel - 2) {
                                    path.append(row.id)
                                }
                                .contextMenu { contextMenu(model, ids: selection.contains(row.id) ? selection.ids : [row.id]) }
                            }
                            // After the user's own containers, not among the system ones.
                            if entry.group.id == groups.last(where: { !$0.group.system })?.group.id && search.isEmpty {
                                RunContainerCard { app.requestRun() }
                            }
                        }
                    }
                }
            }
            .padding(DS.Spacing.xl)
        }
        .background(DS.canvas)
        .overlay(alignment: .bottom) {
            if !selection.isEmpty { selectionBar(model) }
        }
        .accessibilityIdentifier("containers.cards")
    }

    /// Start, stop, restart or delete the selected cards.
    private func selectionBar(_ model: ContainersViewModel) -> some View {
        let chosen = selected(model)
        return SelectionBar(count: chosen.count, onClear: { selection.clear() }) {
            if chosen.contains(where: { !$0.state.isRunning }) {
                Button("Start") { Task { await model.start(selection.ids) } }
            }
            if chosen.contains(where: { $0.state.isRunning }) {
                Button("Stop") { Task { await model.stop(selection.ids) } }
                Button("Restart") { Task { await model.restart(selection.ids) } }
            }
            Button("Delete", role: .destructive) { pendingDelete = selection.ids }
        }
    }

    private func groupHeader(_ group: ContainerList.Group) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s + 2) {
            if let project = group.project {
                Text(project).font(.headline)
                Text("\(group.running) of \(group.containers.count) up")
                    .font(.caption)
                    .foregroundStyle(group.running == group.containers.count ? Tone.positive.text : .secondary)
                Button("Open project →") {
                    app.revealProject = project
                    app.section = .compose
                }
                .buttonStyle(.link).font(.caption)
            } else if group.system {
                Text("System containers").font(.headline)
                Text("machines, cluster nodes and the image builder").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("On their own").font(.headline)
                Text("not part of a project").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func table(_ model: ContainersViewModel, rows: [ContainerRow]) -> some View {
        Table(of: ContainerRow.self, selection: Binding(get: { selection.ids }, set: { selection.set($0) }), sortOrder: $sortOrder,
              columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: DS.Spacing.s) {
                    StatusDot(tone: row.presentation.tone)
                    Text(row.name).fontWeight(.medium)
                    if !row.container.state.isRunning || row.container.state == .stopping {
                        Text(row.presentation.label).font(.caption).foregroundStyle(row.presentation.tone.text)
                    } else if let health = app.health[row.container.id] {
                        HealthBadge(status: health)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "\(row.name), \(row.presentation.label)\(app.health[row.container.id].map { ", \(HealthBadge.label($0))" } ?? "")"))
                .accessibilityIdentifier("containers.row.\(row.id)")
            }
            .width(min: 110, ideal: 180)
            .customizationID("name")

            TableColumn("Image", value: \.image) { row in
                Text(row.image).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 76, ideal: 140)
            .customizationID("image")

            TableColumn("Ports") { row in
                if row.presentation.ports.isEmpty {
                    Text(row.container.state.isRunning ? "internal" : "—").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(row.presentation.ports.prefix(3)) { PortPill(port: $0, target: row.id) }
                        if row.presentation.ports.count > 3 {
                            Text(verbatim: "+\(row.presentation.ports.count - 3)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 68, ideal: 120)

            TableColumn("CPU", value: \.cpuSortKey) { row in
                if let cpu = row.stats?.latestCPU {
                    HStack(spacing: DS.Spacing.s) {
                        Sparkline(samples: row.stats?.cpu ?? [], maxValue: max(100, row.stats?.cpu.max() ?? 0))
                            .frame(width: 26, height: 14)
                        Text("\(Int(cpu.rounded()))%").monospacedDigit()
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 78, ideal: 100)

            TableColumn("Memory", value: \.memorySortKey) { row in
                if let stats = row.stats, stats.memoryUsage > 0 {
                    Text(Format.memory(stats.memoryUsage)).monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 54, ideal: 76)

            TableColumn("Uptime", value: \.uptimeSortKey) { row in
                Text(ContainerPresentation.uptime(row.container) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 70)

            TableColumn("") { row in
                rowActions(model, row.container)
            }
            .width(48)
        } rows: {
            ForEach(groups(rows), id: \.group.id) { entry in
                Section {
                    ForEach(entry.rows) { TableRow($0) }
                } header: {
                    HStack(spacing: DS.Spacing.s) {
                        Text(entry.group.title).fontWeight(.semibold)
                        if entry.group.project != nil {
                            Text("\(entry.group.running) of \(entry.group.containers.count) up")
                                .font(.caption)
                                .foregroundStyle(entry.group.running == entry.group.containers.count
                                                 ? Tone.positive.text : .secondary)
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(model, ids: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { path.append(id) }
        }
        .focused($tableFocused)
        .onChange(of: inspectorShown && !selection.isEmpty, initial: true) { _, inspecting in
            columns[visibility: "image"] = inspecting ? .hidden : .automatic
        }
        .onDeleteCommand { if !selection.isEmpty { pendingDelete = selection.ids } }
        .accessibilityIdentifier("containers.list")
    }

    private func rowActions(_ model: ContainersViewModel, _ container: Container) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if model.busyIDs.contains(container.id) {
                ProgressView().controlSize(.small)
                    .accessibilityIdentifier("container.action.busy.\(container.id)")
            } else if container.state.isRunning {
                Button { Task { await model.stop([container.id]) } } label: { Image(systemName: "stop.fill") }
                    .help("Stop")
                    .accessibilityLabel("Stop \(container.id)")
                    .accessibilityIdentifier("container.action.stop.\(container.id)")
            } else {
                Button { Task { await model.start([container.id]) } } label: { Image(systemName: "play.fill") }
                    .help("Start")
                    .accessibilityLabel("Start \(container.id)")
                    .accessibilityIdentifier("container.action.start.\(container.id)")
            }
            Button { pendingDelete = [container.id] } label: { Image(systemName: "trash") }
                .help("Delete")
                .accessibilityLabel("Delete container \(container.id)")
                .accessibilityIdentifier("container.action.delete.\(container.id)")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func contextMenu(_ model: ContainersViewModel, ids: Set<String>) -> some View {
        let containers = model.containers.filter { ids.contains($0.id) }
        if containers.count == 1, let container = containers.first {
            if let url = ContainerPresentation(container).ports.first?.url {
                Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
            Button("Show Details") { path.append(container.id) }
            Divider()
        }
        if containers.contains(where: { !$0.state.isRunning }) {
            Button("Start") { Task { await model.start(ids) } }
        }
        if containers.contains(where: { $0.state.isRunning }) {
            Button("Stop") { Task { await model.stop(ids) } }
            Button("Restart") { Task { await model.restart(ids) } }
        }
        if containers.count == 1, let container = containers.first {
            Divider()
            Button("Copy ID") { copy(container.id) }
            if let ip = container.ipv4Address { Button("Copy IP Address") { copy(ip) } }
            Button("Copy Run Command") { copy(ContainerList.runCommand(container)) }
        }
        if !containers.isEmpty {
            Divider()
            Button(containers.count == 1 ? "Delete" : "Delete \(containers.count) Containers", role: .destructive) {
                pendingDelete = ids
            }
        }
    }

    private func stateFilter(_ model: ContainersViewModel) -> some View {
        let visible = model.containers.filter { showSystem || !$0.isSystem }
        let running = visible.filter { $0.state.isRunning }.count
        return Picker("Show", selection: $stateFilter) {
            Text("All \(visible.count)").tag(ContainerList.StateFilter.all)
            Text("Running \(running)").tag(ContainerList.StateFilter.running)
            Text("Stopped \(visible.count - running)").tag(ContainerList.StateFilter.stopped)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show containers in this state")
        .accessibilityIdentifier("containers.stateFilter")
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: ContainersViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { stateFilter(model) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Picker("Layout", selection: $layout) {
                Label("Cards", systemImage: "square.grid.2x2").tag(ContainersLayout.cards)
                Label("Table", systemImage: "list.bullet").tag(ContainersLayout.table)
            }
            .pickerStyle(.segmented)
            .help("Cards, or a table you can sort")
            .accessibilityIdentifier("containers.layout")
        }
        if layout == .table {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $inspectorShown) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(inspectorShown ? "Hide inspector" : "Show inspector for the selection")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            // Less used: kept out of sight.
            Menu {
                Toggle("Show System Containers", isOn: $showSystem)
                    .help("The image builder and other containers container runs itself")
                    .accessibilityIdentifier("containers.showSystem")
                Button("Refresh") { Task { await model.load() } }
                    .accessibilityIdentifier("containers.refresh")
                    .disabled(model.isLoading)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More")
            .menuIndicator(.hidden)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Run Container…") { app.requestRun() }
            .buttonStyle(.borderedProminent)
            .help("Run a container (⌘N)")
            .accessibilityIdentifier("containers.run")
        }
    }

    private func footer(_ model: ContainersViewModel) -> some View {
        let visible = model.containers.filter { showSystem || !$0.isSystem }
        let running = visible.filter { $0.state.isRunning }.count
        let hidden = showSystem ? 0 : model.containers.filter(\.isSystem).count
        return HStack(spacing: DS.Spacing.s) {
            Text("\(running) running · \(visible.count - running) stopped")
            if hidden > 0 {
                Text("· \(hidden) system containers hidden")
                Button("Show") { showSystem = true }.buttonStyle(.link)
            }
            Spacer()
            if layout == .table && selection.count > 1 {
                Text("\(selection.count) selected")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.bar)
    }

    @ViewBuilder
    private func inspector(_ model: ContainersViewModel) -> some View {
        let chosen = selected(model)
        if chosen.count == 1, let container = chosen.first {
            ContainerInspector(container: container,
                               stats: stats.series[container.id],
                               isBusy: model.busyIDs.contains(container.id),
                               onStart: { Task { await model.start([container.id]) } },
                               onStop: { Task { await model.stop([container.id]) } },
                               onRestart: { Task { await model.restart([container.id]) } },
                               onOpenDetail: { path.append(container.id) })
        } else if chosen.count > 1 {
            VStack(spacing: DS.Spacing.m) {
                Text("\(chosen.count) containers selected").font(.headline)
                HStack {
                    Button("Start") { Task { await model.start(selection.ids) } }
                    Button("Stop") { Task { await model.stop(selection.ids) } }
                    Button("Restart") { Task { await model.restart(selection.ids) } }
                }
                Button("Delete", role: .destructive) { pendingDelete = selection.ids }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                   description: Text("Select a container to see how to reach it and what it uses."))
        }
    }

    @ViewBuilder
    private func emptyState(_ model: ContainersViewModel) -> some View {
        if search.isEmpty {
            ContainersWelcome()
                .accessibilityIdentifier("containers.emptyState")
        } else {
            ContentUnavailableView.search(text: search)
                .accessibilityIdentifier("containers.emptyState")
        }
    }

    // MARK: - Helpers

    private var deleteTitle: String {
        pendingDelete.count == 1 ? String(localized: "Delete container “\(pendingDelete.first!)”?")
            : String(localized: "Delete \(pendingDelete.count) containers?")
    }

    private func deleteMessage(_ model: ContainersViewModel) -> String {
        let running = model.containers.filter { pendingDelete.contains($0.id) && $0.state.isRunning }.count
        return running > 0
            ? String(localized: "Running ones are stopped first. Files written inside them are lost; volumes are kept. This can't be undone.")
            : String(localized: "Files written inside are lost; volumes are kept. This can't be undone.")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A table row: the container plus its live stats, with sortable keys.
struct ContainerRow: Identifiable, Equatable {
    let container: Container
    let stats: LiveStats.Series?

    var id: String { container.id }
    var name: String { container.id }
    var image: String { container.imageShortName }
    var presentation: ContainerPresentation { ContainerPresentation(container) }
    var cpuSortKey: Double { stats?.latestCPU ?? -1 }
    var memorySortKey: Int64 { stats?.memoryUsage ?? -1 }
    /// Seconds since start; stopped containers sort last.
    var uptimeSortKey: Double { container.startedDate.map { -$0.timeIntervalSinceNow } ?? -1 }
}

/// A running container's health check result (run by the background agent).
struct HealthBadge: View {
    let status: String

    var body: some View {
        let tone: Tone = status == "healthy" ? .positive : status == "unhealthy" ? .critical : .warning
        Label(Self.label(status),
              systemImage: status == "healthy" ? "heart.fill" : status == "unhealthy" ? "heart.slash.fill" : "heart")
            .font(.caption)
            .foregroundStyle(tone.text)
            .labelStyle(.titleAndIcon)
            .help("Health check: \(Self.label(status))")
    }

    /// The health status as shown: "checking" while it starts.
    static func label(_ status: String) -> String {
        switch status {
        case "healthy": String(localized: "healthy", comment: "Health check status")
        case "unhealthy": String(localized: "unhealthy", comment: "Health check status")
        case "starting": String(localized: "checking", comment: "Health check status: the first check is running")
        default: status
        }
    }
}

/// No containers yet: what a container is, four ways to try one, and the
/// way over from Docker Desktop.
struct ContainersWelcome: View {
    @Environment(AppState.self) private var app

    private struct Start: Identifiable {
        let title: LocalizedStringResource
        let image: String
        let detail: LocalizedStringResource
        let configure: (inout RunConfiguration) -> Void
        var paste = false
        var id: String { image }
    }

    private static let starts: [Start] = [
        Start(title: "A web page", image: "nginx", detail: "See it in your browser at localhost:8080") {
            $0.image = "nginx:alpine"
            $0.name = "web"
            $0.ports = [.init(host: "8080", container: "80")]
        },
        Start(title: "A database", image: "postgres", detail: "Ready for your app on localhost:5432") {
            $0.image = "postgres:17-alpine"
            $0.name = "db"
            $0.ports = [.init(host: "5432", container: "5432")]
            $0.variables = [.init(key: "POSTGRES_PASSWORD", value: "postgres")]
        },
        Start(title: "A Linux shell", image: "alpine", detail: "Poke around in a throwaway system") {
            $0.image = "alpine:latest"
            $0.name = "playground"
            $0.command = "sleep infinity"
            $0.removeWhenStopped = true
        },
        Start(title: "Your own", image: "docker run …", detail: "Paste a command from any tutorial", configure: { _ in },
              paste: true),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                VStack(spacing: DS.Spacing.m + 2) {
                    illustration
                    Text("No containers yet").font(.title2.weight(.bold))
                    Text("A container is one app running in isolation. Pick one to try — it starts in seconds and you can delete it any time.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .padding(.top, 50)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: DS.Spacing.m + 2)],
                          spacing: DS.Spacing.m + 2) {
                    ForEach(Self.starts) { start in
                        VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
                            Text(start.title).font(.headline)
                            Text(start.image).font(DS.Font.monoSmall).foregroundStyle(.secondary)
                            Text(start.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .panel()
                        .cardAction(cornerRadius: DS.Radius.panel) { run(start) }
                        .help(start.paste ? "Paste a docker run command" : "Run \(start.image)")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("containers.start.\(start.image)")
                    }
                }
                HStack(spacing: DS.Spacing.xs) {
                    Text("Coming from Docker Desktop?")
                    Button("Bring your containers over") { app.section = .migrate }.buttonStyle(.link)
                    Text("— nothing is deleted there.")
                }
                .font(.callout)
                .padding(.horizontal, DS.Spacing.l).padding(.vertical, DS.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.accent.opacity(0.06)))
                .hairline(RoundedRectangle(cornerRadius: DS.Radius.card), DS.accent.opacity(0.25))
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(DS.accent.opacity(0.1))
                .strokeBorder(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .frame(width: 76, height: 56)
            Image(systemName: "shippingbox").font(.system(size: 26)).foregroundStyle(DS.accent)
        }
        .frame(width: 120, height: 90)
        .accessibilityHidden(true)
    }

    private func run(_ start: Start) {
        var configuration = RunConfiguration()
        start.configure(&configuration)
        app.requestRun(configuration, paste: start.paste)
    }
}

