import SwiftUI
import ContainerKit
import ComposeKit
import EngineCore

/// One compose project: a map of its services and ways in, the services'
/// logs together, and what in its compose file runs differently here.
struct ComposeProjectView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let name: String
    let model: ComposeViewModel

    enum Tab: String, CaseIterable, Identifiable {
        case map = "Map", logs = "Logs", file = "Compose File"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .map: return String(localized: "Map")
            case .logs: return String(localized: "Logs")
            case .file: return String(localized: "Compose File")
            }
        }
    }

    @State private var tab: Tab = .map
    /// Unsaved edits per file, kept while switching tabs.
    @State private var drafts: [String: String] = [:]
    @State private var confirmRemoveContainers = false
    @State private var confirmRemoveProject = false
    /// The service in the inspector.
    @State private var selected: String?
    @State private var arrangeRequest = 0
    /// Map scale, kept between projects and launches.
    @AppStorage("composeMapZoom") private var zoom = 1.0
    @State private var stats = LiveStats()

    var body: some View {
        Group {
            if let project = model.project(named: name) {
                content(project)
            } else {
                ContentUnavailableView("Project Removed", systemImage: "square.stack.3d.up.slash",
                                       description: Text("Its containers were removed."))
            }
        }
        .navigationTitle(name)
        .navigationSubtitle(subtitle)
        .task(id: name) {
            let stats = self.stats
            await stats.run(engine: app.engine) { [model, name] in
                model.project(named: name)?.containers.filter { $0.state.isRunning }.map(\.id) ?? []
            }
        }
    }

    /// "~/Code/shop · Run by Irekobox"
    private var subtitle: String {
        guard let project = model.project(named: name) else { return "" }
        let origin = project.isManagedHere ? String(localized: "Run by Irekobox") : String(localized: "Started with docker compose")
        guard let directory = project.directory else { return origin }
        return (directory as NSString).abbreviatingWithTildeInPath + " · " + origin
    }

    private func content(_ project: ComposeProject) -> some View {
        let services = model.services(of: project)
        let busy = model.busy.contains(project.name)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                switch tab {
                case .map: mapTab(project, services)
                case .logs: logsTab(project, services)
                case .file: ComposeFileTab(project: project, model: model, drafts: $drafts)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the header on top whatever the tab holds (an empty state centers otherwise).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar { toolbar(project, busy: busy) }
        .toolbar {
            // Switching what the window shows: centred, as macOS places view switchers.
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("compose.tabs")
            }
        }
        .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
        .confirmationDialog("Remove the containers of “\(project.name)”?", isPresented: $confirmRemoveContainers,
                            titleVisibility: .visible) {
            Button("Remove Containers", role: .destructive) { Task { await model.removeContainers(project) } }
        } message: {
            Text("They're stopped and deleted. Volumes and project files stay; Start creates them again.")
        }
        .confirmationDialog("Remove “\(project.name)” from Irekobox?", isPresented: $confirmRemoveProject,
                            titleVisibility: .visible) {
            Button("Remove Project", role: .destructive) { Task { await model.remove(project); dismiss() } }
        } message: {
            Text("Its containers are deleted. Volumes and the compose file stay.")
        }
    }

    // MARK: - Map

    private func mapTab(_ project: ComposeProject, _ services: [ComposeService]) -> some View {
        let binds = model.bindMounts(of: project)
        let inspected = services.first { $0.name == selected }
        return HStack(spacing: 0) {
            ScrollView([.vertical]) {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    if services.isEmpty {
                        Text("No services found: the compose file can't be read and no containers run.")
                            .foregroundStyle(.secondary)
                    } else {
                        Zoomed(scale: zoom) {
                            ComposeMap(project: project.name, services: services, health: app.health,
                                       selected: selected, stats: stats.series, arrangeRequest: arrangeRequest) { service in
                                withAnimation(.snappy) { selected = selected == service.name ? nil : service.name }
                            }
                        }
                    }
                    if !binds.isEmpty { BindMountHint(mounts: binds) }
                }
                .padding(DS.Spacing.l)
                // Room for the panels floating over the bottom of the map.
                .padding(.bottom, 56)
            }
            .background { DotGrid() }
            .overlay(alignment: .bottomLeading) { if !services.isEmpty { legend.padding(DS.Spacing.l) } }
            .overlay(alignment: .bottomTrailing) {
                if !services.isEmpty {
                    HStack(spacing: DS.Spacing.s) {
                        Button { zoom = max(0.5, ((zoom - 0.1) * 10).rounded() / 10) } label: { Image(systemName: "minus") }
                            .buttonStyle(.automatic)
                            .disabled(zoom <= 0.5)
                            .help("Zoom out")
                            .accessibilityLabel("Zoom out")
                        Button { zoom = min(1.5, ((zoom + 0.1) * 10).rounded() / 10) } label: { Image(systemName: "plus") }
                            .buttonStyle(.automatic)
                            .disabled(zoom >= 1.5)
                            .help("Zoom in")
                            .accessibilityLabel("Zoom in")
                        Button("Auto Arrange") { arrangeRequest += 1 }
                            .buttonStyle(.automatic)
                            .help("Lay the cards out in tidy rows, with fewer crossing lines")
                    }
                    .floatingPanel()
                    .padding(DS.Spacing.l)
                }
            }
            if let inspected {
                Divider()
                ServiceInspector(service: inspected, services: services,
                                 stats: inspected.containers.first.flatMap { stats.series[$0.id] },
                                 health: inspected.containers.lazy.compactMap { app.health[$0.id] }.first)
                    .frame(width: 320)
                    .background(.regularMaterial)
                    .overlay(alignment: .topTrailing) {
                        Button { withAnimation(.snappy) { selected = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(DS.Spacing.m)
                        .help("Close")
                        .accessibilityLabel("Close details")
                        .keyboardShortcut(.cancelAction)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: DS.Spacing.l) {
            legendItem(dashed: false, color: DS.accent, "Way in from this Mac")
            legendItem(dashed: true, color: .secondary, "Depends on")
            Label("Volume", systemImage: "externaldrive")
            Label("Folder on this Mac", systemImage: "folder")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .floatingPanel()
        .help("Drag cards to arrange them; click one for its details.")
    }

    private func legendItem(dashed: Bool, color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: 22, y: 5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
            .frame(width: 22, height: 10)
            Text(title)
        }
    }

    // MARK: - Logs

    @ViewBuilder
    private func logsTab(_ project: ComposeProject, _ services: [ComposeService]) -> some View {
        let sources = services.flatMap { service in
            service.containers.map { (label: service.containers.count > 1 ? $0.id : service.name, id: $0.id) }
        }
        if sources.isEmpty {
            ContentUnavailableView("No Containers", systemImage: "text.alignleft",
                                   description: Text("Start the project to see its services' output here."))
        } else {
            LogsTab(id: project.name, sources: sources,
                    window: LogsTarget(title: project.name, sources: sources.map { .init(label: $0.label, id: $0.id) }))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ project: ComposeProject, busy: Bool) -> some ToolbarContent {
        if busy {
            // A status, not a control: outside the glass, apart from the buttons.
            ToolbarItem(placement: .primaryAction) { ProgressView().controlSize(.small) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let directory = project.directory {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
                    }
                    Divider()
                }
                if project.isManagedHere {
                    Button("Recreate") { Task { await model.recreate(project) } }
                        .help("Delete the containers and run the compose file again, e.g. after editing it")
                }
                Divider()
                if let path = project.composePath {
                    Button("Open Compose File") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
                Divider()
                Button("Remove Containers", role: .destructive) { confirmRemoveContainers = true }
                    .disabled(project.containers.isEmpty)
                if project.isManagedHere {
                    Button("Remove Project", role: .destructive) { confirmRemoveProject = true }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More")
            .menuIndicator(.hidden)
            .disabled(busy)
        }
        if project.running > 0 {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Restart") { Task { await model.restart(project) } }
                    .help("Restart every service")
                    .disabled(busy)
                Button("Stop") { Task { await model.stop(project) } }
                    .help("Stop every service")
                    .disabled(busy)
            }
        }
        if project.containers.isEmpty || project.running < project.containers.count {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Start") { Task { await model.start(project) } }
                    .help(project.isManagedHere ? "Start the services, creating any that don't exist yet"
                                                : "Start the stopped services")
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (!project.isManagedHere && project.containers.isEmpty))
            }
        }
    }
}

/// The compose file, editable: checked as you type, with what applying it
/// would change; Save, or Save & Apply to bring the project in line.
struct ComposeFileTab: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    let project: ComposeProject
    let model: ComposeViewModel
    @Binding var drafts: [String: String]
    /// In its own window: the editor alone, Apply in the toolbar, the check
    /// in a status line.
    var compact = false

    @State private var file: String?
    @State private var saved = ""
    @State private var check: Result<(plan: ComposePlan, changes: [ComposeViewModel.Change]), Error>?
    @State private var showCommands = false
    @State private var saveError: String?

    private var path: String? { file ?? project.configFiles.first }

    private var text: Binding<String> {
        Binding(get: { path.flatMap { drafts[$0] } ?? saved },
                set: { value in if let path { drafts[path] = value } })
    }

    private var isDirty: Bool { path.flatMap { drafts[$0] }.map { $0 != saved } ?? false }
    private var isValid: Bool { if case .success = check { return true } else { return false } }

    var body: some View {
        if let path, compact {
            VStack(spacing: 0) {
                YAMLEditor(text: text, images: app.model.images.filter { !$0.isSystem }.map(\.shortName).sorted())
                Divider()
                statusLine
            }
            .navigationTitle((path as NSString).lastPathComponent + " — " + project.name)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Revert") { drafts[path] = nil }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(applyTitle) { apply(path) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!isValid || !isDirty || model.busy.contains(project.name))
                }
            }
            .task(id: path) { load(path) }
            .task(id: text.wrappedValue) {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                check = model.preview(project, text: text.wrappedValue)
            }
        } else if let path {
            HSplitView {
                VStack(spacing: 0) {
                    bar(path)
                    Divider()
                    YAMLEditor(text: text, images: app.model.images.filter { !$0.isSystem }.map(\.shortName).sorted())
                }
                .frame(minWidth: 380)
                sidePanel
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            }
            .task(id: path) { load(path) }
            .task(id: text.wrappedValue) {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                check = model.preview(project, text: text.wrappedValue)
            }
        } else {
            ContentUnavailableView("No Compose File", systemImage: "doc.questionmark",
                                   description: Text("Docker Compose didn't record where this project's file is."))
        }
    }

    /// What Apply would do, counted.
    private var pending: [ComposeViewModel.Change] {
        guard case .success(let result) = check else { return [] }
        return result.changes.filter { if case .keep = $0 { return false } else { return true } }
    }

    private var applyTitle: String {
        guard project.isManagedHere, isDirty, !pending.isEmpty else { return String(localized: "Apply") }
        return String(localized: "Apply \(pending.count) Changes")
    }

    private func apply(_ path: String) {
        Task {
            await model.apply(project, text: text.wrappedValue, to: path,
                              dockerSocket: app.dockerSocketEnabled ? DockerSocketStatus.defaultPath : nil)
            load(path)
            if model.error == nil { drafts[path] = nil }
        }
    }

    /// "✓ Valid · only api will be recreated".
    private var statusLine: some View {
        HStack(spacing: DS.Spacing.s) {
            switch check {
            case .failure(let error):
                Label(Self.readable(error), systemImage: "xmark.octagon").foregroundStyle(Tone.critical.text)
            case .success:
                Label("Valid · \(summary)", systemImage: "checkmark").foregroundStyle(Tone.positive.text)
            case nil:
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if model.busy.contains(project.name) { Text("Applying…").foregroundStyle(.secondary) }
            if let saveError { Text(saveError).foregroundStyle(Tone.critical.text) }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, DS.Spacing.m)
        .frame(height: 30)
        .background(DS.subtleFill)
    }

    private var summary: String {
        guard project.isManagedHere else { return String(localized: "docker compose applies it") }
        guard isDirty else { return String(localized: "no changes") }
        var recreated: [String] = [], added: [String] = [], removed: [String] = []
        for change in pending {
            switch change {
            case .recreate(let service, _): recreated.append(service)
            case .add(let service): added.append(service)
            case .remove(let container): removed.append(container)
            case .keep: break
            }
        }
        func list(_ names: [String]) -> String { ListFormatter.localizedString(byJoining: names) }
        var parts: [String] = []
        if !recreated.isEmpty {
            if added.isEmpty && removed.isEmpty && recreated.count == 1 {
                parts.append(String(localized: "only \(list(recreated)) will be recreated"))
            } else {
                parts.append(String(localized: "\(list(recreated)) will be recreated"))
            }
        }
        if !added.isEmpty { parts.append(String(localized: "\(list(added)) will be created")) }
        if !removed.isEmpty { parts.append(String(localized: "\(list(removed)) will be removed")) }
        return parts.isEmpty ? String(localized: "nothing to recreate") : parts.joined(separator: ", ")
    }

    private func load(_ path: String) {
        saved = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        saveError = nil
    }

    private func bar(_ path: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if project.configFiles.count > 1 {
                Picker("File", selection: Binding(get: { path }, set: { file = $0 })) {
                    ForEach(project.configFiles, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Label((path as NSString).lastPathComponent, systemImage: "doc.text").font(.callout.weight(.medium))
            }
            if isDirty {
                Text("Edited").font(.caption).foregroundStyle(Tone.warning.text)
            }
            Spacer()
            Button {
                openWindow(id: "compose-file", value: project.name)
            } label: {
                Image(systemName: "macwindow.badge.plus")
            }
            .help("Edit in its own window")
            .accessibilityLabel("Edit in its own window")
            Button("Revert") { drafts[path] = nil }
                .disabled(!isDirty)
            Button("Save") { save(path) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty)
            Button(project.isManagedHere ? "Save & Apply" : "Save & Apply with docker compose") {
                Task {
                    await model.apply(project, text: text.wrappedValue, to: path,
                                      dockerSocket: app.dockerSocketEnabled ? DockerSocketStatus.defaultPath : nil)
                    load(path)
                    if model.error == nil { drafts[path] = nil }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!isValid || model.busy.contains(project.name))
            .help(project.isManagedHere
                  ? "Save, then recreate only the services whose settings changed"
                  : "Save, then run docker compose up -d through Irekobox's Docker API")
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
    }

    private func save(_ path: String) {
        do {
            try text.wrappedValue.write(toFile: path, atomically: true, encoding: .utf8)
            load(path)
            drafts[path] = nil
        } catch {
            saveError = String(localized: "Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: - Side panel

    private var sidePanel: some View {
        List {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
            }
            if model.busy.contains(project.name) {
                Label("Applying…", systemImage: "arrow.triangle.2.circlepath")
            }
            switch check {
            case .failure(let error):
                Section("Problem") {
                    Label(Self.readable(error), systemImage: "xmark.octagon")
                        .foregroundStyle(Tone.critical.text)
                        .textSelection(.enabled)
                }
            case .success(let result):
                Section("On Apply") { changes(result.changes) }
                Section("Compatibility") {
                    if result.plan.warnings.isEmpty {
                        Label("Everything runs as written.", systemImage: "checkmark.circle")
                            .foregroundStyle(Tone.positive.text)
                    }
                    ForEach(Array(result.plan.warnings.enumerated()), id: \.offset) { _, warning in
                        warningRow(warning)
                    }
                }
                if project.isManagedHere {
                    Section {
                        DisclosureGroup("Commands Irekobox runs", isExpanded: $showCommands) {
                            ForEach(result.plan.steps) { step in
                                Text(step.displayCommand)
                                    .font(DS.Font.monoSmall).textSelection(.enabled).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    /// YAML errors as "Line 7, column 5: could not find expected ':'".
    static func readable(_ error: Error) -> String {
        let text = error.localizedDescription
        guard let match = text.firstMatch(of: /line (\d+), column (\d+)\s*([^\n]*)/) else { return text }
        let reason = text[match.range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        let what = String(match.output.3).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return String(localized: "Line \(String(match.output.1)), column \(String(match.output.2)): \(what.isEmpty ? reason : what)")
    }

    @ViewBuilder
    private func changes(_ changes: [ComposeViewModel.Change]) -> some View {
        if !project.isManagedHere {
            Text(app.dockerSocketEnabled
                 ? "docker compose recreates the services whose settings changed."
                 : "Turn on the Docker API (Settings › Engine) to apply with docker compose; Save works anyway.")
                .font(.callout).foregroundStyle(.secondary)
        } else if changes.allSatisfy({ if case .keep = $0 { return true } else { return false } }) && !changes.isEmpty {
            Label("Nothing to change: every service runs as written.", systemImage: "checkmark.circle")
                .foregroundStyle(Tone.positive.text)
        } else {
            ForEach(changes) { change in
                switch change {
                case .add(let service):
                    Label("\(service): created", systemImage: "plus.circle").foregroundStyle(Tone.positive.text)
                case .recreate(let service, _):
                    Label("\(service): recreated", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Tone.warning.text)
                        .help("Its settings changed (or were set before Irekobox recorded them). Volumes stay.")
                case .keep(let service):
                    Label("\(service): unchanged", systemImage: "equal.circle").foregroundStyle(.secondary)
                case .remove(let container):
                    Label("\(container): removed", systemImage: "minus.circle").foregroundStyle(Tone.critical.text)
                        .help("No longer in the file. Its volumes stay.")
                }
            }
        }
    }

    private func warningRow(_ warning: PlanWarning) -> some View {
        let tone: Tone = warning.severity == .unsupported ? .critical : warning.severity == .partial ? .warning : .neutral
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: warning.severity == .unsupported ? "xmark.octagon"
                  : warning.severity == .partial ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(tone.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(warning.service.map { "\($0) · \(warning.field)" } ?? warning.field)
                    .font(.callout.weight(.medium))
                Text(warning.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A compose file in its own window (`compose-file` with the project's name).
public struct ComposeFileWindow: View {
    let name: String?
    @Environment(AppState.self) private var app
    @State private var model: ComposeViewModel?
    @State private var drafts: [String: String] = [:]

    public init(name: String?) { self.name = name }

    public var body: some View {
        Group {
            if let name, let model, let project = model.project(named: name) {
                ComposeFileTab(project: project, model: model, drafts: $drafts, compact: true)
            } else if model == nil || model?.projects.isEmpty == true {
                ProgressView()
            } else {
                ContentUnavailableView("No Project", systemImage: "doc.questionmark",
                                       description: name.map { Text("\($0) isn't on this Mac any more.") }
                                           ?? Text("This project isn't on this Mac any more."))
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            if model == nil {
                let model = ComposeViewModel(engine: app.engine, runner: app.composeRunner)
                model.onHandAction = { [weak app] stopped, ids in app?.noteHandAction(stopped: stopped, ids) }
                self.model = model
            }
        }
        .task { await app.model.observe([.containers]) }
        .task(id: app.model.containers) { await model?.reload() }
    }
}
