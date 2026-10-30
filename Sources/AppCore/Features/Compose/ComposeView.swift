import SwiftUI
import UniformTypeIdentifiers
import ContainerKit

/// Compose projects: the ones added here and the ones `docker compose`
/// started. Open (or drop) a folder or compose file to add one.
struct ComposeView: View {
    @Environment(AppState.self) private var app
    @State private var model: ComposeViewModel?
    @State private var importing = false
    @State private var path: [String] = []
    @State private var dropTargeted = false
    /// The New Project sheet, opened on this template.
    @State private var newProject: ComposeTemplate?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            // Empty states and loading sit on the canvas too, not on the window's white.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.canvas)
            .navigationTitle("Compose")
            .navigationSubtitle("Several containers from one compose.yaml, started together")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open compose.yaml…") { importing = true }
                        .help("Add a project folder or compose file")
                        .accessibilityIdentifier("stacks.add")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button("New Project…") { newProject = .web }
                        .buttonStyle(.borderedProminent)
                        .help("Make a folder with a starter compose.yaml and open it here")
                        .accessibilityIdentifier("compose.new")
                }
            }
            .navigationDestination(for: String.self) { name in
                if let model { ComposeProjectView(name: name, model: model) }
            }
            .onChange(of: app.revealProject, initial: true) { _, name in
                guard let name else { return }
                path = [name]
                app.revealProject = nil
            }
        }
        .onAppear {
            if model == nil {
                let model = ComposeViewModel(engine: app.engine, runner: app.composeRunner)
                model.onHandAction = { [weak app] stopped, ids in app?.noteHandAction(stopped: stopped, ids) }
                self.model = model
            }
        }
        .task { await app.model.observe([.containers]) }
        // The model's containers are what changed: no second listing.
        .task(id: app.model.containers) {
            await model?.reload(containers: app.model.isLoading(.containers) ? nil : app.model.containers)
        }
        .sheet(item: $newProject) { template in
            NewProjectSheet(initial: template) { chosen, folder in create(chosen, in: folder) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .yaml],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { open(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(DS.Spacing.s)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Write the template's compose.yaml into a new folder and open the project.
    private func create(_ template: ComposeTemplate, in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "compose.yaml")
            if !FileManager.default.fileExists(atPath: file.path) {
                try template.yaml.write(to: file, atomically: true, encoding: .utf8)
            }
            open(folder)
        } catch {
            model?.error = error.localizedDescription
        }
    }

    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let name = model?.add(url) { path = [name] }
    }

    @ViewBuilder
    private func content(_ model: ComposeViewModel) -> some View {
        if model.loaded && model.projects.isEmpty {
            ContentUnavailableView {
                Label("No Compose Projects", systemImage: "square.stack.3d.up")
            } description: {
                Text("Run `docker compose up` in a project folder and it shows up here, or open the folder to run it from Irekobox. You can also drop a folder or compose.yaml on this window.")
            } actions: {
                Button("Open Project…") { importing = true }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 480), spacing: DS.Spacing.l)],
                              spacing: DS.Spacing.l) {
                        ForEach(model.projects) { project in
                            ComposeProjectCard(project: project, model: model) { path.append(project.name) }
                                .contextMenu { menu(model, project) }
                        }
                    }
                    addCard
                    LearnNote("**A compose project** is several containers described in one file. Edit it here or in your editor — Irekobox notices the change and offers to apply only what changed.")
                }
                .padding(DS.Spacing.l)
            }
            .background(DS.canvas)
            .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
        }
    }

    /// Where a compose file can be dropped or chosen.
    private var addCard: some View {
        HStack(spacing: DS.Spacing.l) {
            Image(systemName: "plus").font(.title2).foregroundStyle(DS.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop a compose.yaml here").font(.callout.weight(.semibold)).foregroundStyle(DS.accent)
                HStack(spacing: 4) {
                    Text("Or start from a template:").foregroundStyle(.secondary)
                    ForEach(ComposeTemplate.all.dropFirst()) { template in
                        Button(template.title) { newProject = template }
                            .buttonStyle(.link)
                        if template != ComposeTemplate.all.last { Text("·").foregroundStyle(.tertiary) }
                    }
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .strokeBorder(DS.accent.opacity(dropTargeted ? 0.9 : 0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
        .cardAction(cornerRadius: DS.Radius.panel) { importing = true }
        .accessibilityLabel("Open Project")
        .accessibilityIdentifier("compose.addCard")
    }

    @ViewBuilder
    private func menu(_ model: ComposeViewModel, _ project: ComposeProject) -> some View {
        if project.running < project.containers.count || project.containers.isEmpty {
            Button("Start") { Task { await model.start(project) } }
        }
        if project.running > 0 {
            Button("Stop") { Task { await model.stop(project) } }
        }
        if let directory = project.directory {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)]) }
        }
    }
}

/// One project: name and state, folder, its services, ways in, and a
/// quick Start / Stop. Clicking the card opens the project.
struct ComposeProjectCard: View {
    let project: ComposeProject
    let model: ComposeViewModel
    let open: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var hovering = false

    var body: some View {
        let services = model.services(of: project)
        let links = liveLinks(services)
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(project.running > 0 ? DS.accent : Color.secondary)
                Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
                if !project.isManagedHere {
                    Text(verbatim: "docker compose")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().strokeBorder(DS.separator))
                        .foregroundStyle(.secondary)
                        .help("Started with docker compose; found by its labels")
                }
                Spacer(minLength: DS.Spacing.s)
                if model.busy.contains(project.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Text(stateText).font(.callout).foregroundStyle(stateTone.text)
                }
            }
            if let directory = project.directory {
                Label((directory as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .font(DS.Font.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(directory)
            }
            if !services.isEmpty {
                ServiceMiniMap(services: services)
                    .frame(height: 96)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(services.map { "\($0.name), \($0.stateLabel)" }.joined(separator: "; "))
            }
            if let change = model.fileChanges[project.name] {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(Tone.warning.fill).accessibilityHidden(true)
                    Text(changeText(change)).font(.callout).foregroundStyle(Tone.warning.text)
                    Spacer(minLength: 0)
                    Button("Apply") { Task { await model.applySavedFile(project) } }
                        .controlSize(.small)
                        .disabled(model.busy.contains(project.name))
                        .help("Recreate only the services whose settings changed")
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Spacing.xs) {
                ForEach(services) { service in StatusDot(tone: service.tone, size: 8) }
                Text("\(services.count) services")
                    .font(.callout).foregroundStyle(.secondary).padding(.leading, 2)
                Spacer(minLength: DS.Spacing.s)
                ForEach(links.prefix(2), id: \.self) { url in
                    Button { openURL(url) } label: {
                        Text(verbatim: ":\(String(url.port ?? 80)) ↗")
                            .font(DS.Font.monoSmall.weight(.semibold))
                            .padding(.horizontal, DS.Spacing.s).padding(.vertical, 3)
                            .background(Capsule().fill(DS.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .help("Open \(url.absoluteString)")
                }
                quickAction
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .panel()
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .strokeBorder(DS.accent.opacity(hovering ? 0.6 : 0), lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.name)
        .cardAction(cornerRadius: DS.Radius.panel, open)
    }

    /// Start when nothing runs; stopping lives in the context menu and the project page.
    @ViewBuilder
    private var quickAction: some View {
        let busy = model.busy.contains(project.name)
        if project.running == 0, project.isManagedHere || !project.containers.isEmpty {
            Button("Start") { Task { await model.start(project) } }
                .buttonStyle(.automatic)
                .disabled(busy)
        }
    }

    /// "Running", "Stopped", "Running · file changed".
    private var stateText: String {
        let base: String
        switch project.summary {
        case .notCreated: base = String(localized: "Not started")
        case .running: base = String(localized: "Running")
        case .stopped: base = String(localized: "Stopped")
        case .partial(let running, let total): base = String(localized: "\(running) of \(total) running")
        }
        return model.fileChanges[project.name] == nil ? base : String(localized: "\(base) · file changed", comment: "A project state, e.g. Running, followed by a note that its compose file changed")
    }

    private var stateTone: Tone {
        if model.fileChanges[project.name] != nil { return .warning }
        switch project.summary {
        case .running: return .positive
        case .partial: return .warning
        case .notCreated, .stopped: return .neutral
        }
    }

    /// "compose.yaml changed 5 min ago · 2 services differ"
    private func changeText(_ change: ComposeViewModel.FileChange) -> String {
        let file = project.composePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "The compose file")
        if let saved = change.saved {
            let when = saved.formatted(.relative(presentation: .named))
            return String(localized: "\(file) changed \(when) · \(change.services) services differ",
                          comment: "The middle part is a relative time such as \"5 min ago\"")
        }
        return String(localized: "\(file) changed · \(change.services) services differ")
    }

    private func liveLinks(_ services: [ComposeService]) -> [URL] {
        services.filter { $0.tone == .positive }.flatMap(\.access).compactMap { access -> URL? in
            if case .port(let port, true) = access { return port.url }
            return nil
        }
    }
}

struct ComposeSummaryPill: View {
    let project: ComposeProject

    var body: some View {
        switch project.summary {
        case .notCreated: StatusPill(tone: .inactive, label: "Not started")
        case .running: StatusPill(tone: .positive, label: "Running", detail: "\(project.containers.count)")
        case .stopped: StatusPill(tone: .neutral, label: "Stopped")
        case .partial(let running, let total): StatusPill(tone: .warning, label: "Partly running", detail: "\(running)/\(total)")
        }
    }
}

/// A project's services in miniature, in the map's rows: what this Mac
/// reaches on top, what they need below, linked by dashed lines.
struct ServiceMiniMap: View {
    let services: [ComposeService]

    var body: some View {
        Canvas { context, size in
            let published = Set(services.filter { !$0.ports.isEmpty }.map(\.name))
            let rows = ComposeTopology.rows(services, top: published)
            guard !rows.isEmpty else { return }
            let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
            let rowHeight = size.height / CGFloat(rows.count)
            // Room between rows for the links to show.
            let nodeHeight = max(12, min(18, rowHeight - 12))
            var frames: [String: CGRect] = [:]
            for (index, row) in rows.enumerated() {
                let gap: CGFloat = 8
                let width = min(84, (size.width - gap * CGFloat(row.count - 1)) / CGFloat(row.count))
                let total = width * CGFloat(row.count) + gap * CGFloat(row.count - 1)
                var x = (size.width - total) / 2
                let y = rowHeight * CGFloat(index) + (rowHeight - nodeHeight) / 2
                for name in row {
                    frames[name] = CGRect(x: x, y: y, width: width, height: nodeHeight)
                    x += width + gap
                }
            }
            for service in services {
                for dependency in service.dependsOn {
                    guard let a = frames[service.name], let b = frames[dependency] else { continue }
                    var path = Path()
                    let start = CGPoint(x: a.midX, y: a.maxY), end = CGPoint(x: b.midX, y: b.minY)
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: (start.y + end.y) / 2),
                                  control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
                    context.stroke(path, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            for (name, frame) in frames {
                let tone = byName[name]?.tone ?? .inactive
                let shape = Path(roundedRect: frame, cornerRadius: 6)
                // Opaque under the tint, so the links pass behind the pills.
                context.fill(shape, with: .color(DS.raised))
                context.fill(shape, with: .color(tone.fill.opacity(0.12)))
                context.stroke(shape, with: .color(tone.fill.opacity(0.7)), lineWidth: 1)
                var label = context.resolve(Text(name).font(.caption2.weight(.medium)).foregroundStyle(.primary))
                label.shading = .color(.primary)
                context.drawLayer { layer in
                    layer.clip(to: Path(frame.insetBy(dx: 3, dy: 0)))
                    layer.draw(label, at: CGPoint(x: frame.midX, y: frame.midY))
                }
            }
        }
    }
}
