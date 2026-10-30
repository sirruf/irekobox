import SwiftUI
import ContainerKit
import EngineCore

/// Overview, the living home: is everything OK and how many apps run, what
/// they use, a live map of where they run, and what just happened.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    @State private var stats = LiveStats()
    @State private var clusters: [Cluster] = []
    @State private var confirmCleanup = false
    @State private var pulling: Set<String> = []
    @State private var find = ""

    private var containers: [Container] { app.model.containers.filter { !$0.isSystem } }
    private var running: [Container] { containers.filter { $0.state.isRunning } }
    private var runningMachines: [Container] { app.model.containers.filter { $0.isMachine && $0.state.isRunning } }
    private var userImages: [ContainerImage] { app.model.images.filter { !$0.isSystem } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l + DS.Spacing.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Spacing.l + DS.Spacing.xs) {
                        hero.frame(minWidth: 420)
                        usage.frame(minWidth: 360, maxWidth: 440)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: DS.Spacing.l + DS.Spacing.xs) { hero; usage }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Spacing.l + DS.Spacing.xs) {
                        map.frame(minWidth: 480)
                        activity.frame(minWidth: 280, maxWidth: 380)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: DS.Spacing.l + DS.Spacing.xs) { map; activity }
                }
                FirstSteps()
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.canvas)
        .accessibilityIdentifier("dashboard.scrollView")
        .navigationTitle("Overview")
        .navigationSubtitle(greeting)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Run Container…") { app.requestRun() }
                    .buttonStyle(.borderedProminent)
                    .help("Run a container (⌘N)")
            }
        }
        // Overview has no list of its own to filter: what's typed here goes
        // to the ⌘K palette, which finds anything.
        .searchable(text: $find, placement: .toolbar, prompt: "Find anything")
        .onChange(of: find) { _, text in
            guard !text.isEmpty else { return }
            app.paletteQuery = text
            find = ""
            app.showPalette = true
        }
        .task { await app.model.observe([.containers, .images, .diskUsage]) }
        .task {
            let stats = self.stats
            await stats.run(engine: app.engine, interval: .seconds(3)) { [app] in
                app.model.containers.filter { $0.state.isRunning && !$0.isSystem }.map(\.id)
            }
        }
        .task {
            let repository = ClusterRepository(cli: app.cli, stream: CLIStream(binaryPath: Settings.shared.binaryPath))
            while !Task.isCancelled {
                if let list = try? await repository.list() { clusters = list }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .confirmationDialog("Free up disk space?", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Remove Stopped Containers", role: .destructive) {
                Task { await app.perform(refreshing: [.containers, .diskUsage]) { try await app.engine.pruneContainers() } }
            }
            Button("Remove Unused Images", role: .destructive) {
                Task { await app.perform(refreshing: [.images, .diskUsage]) { try await app.engine.pruneImages(all: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanupMessage)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 5 { return String(localized: "Good night — here is everything running on this Mac") }
        if hour < 12 { return String(localized: "Good morning — here is everything running on this Mac") }
        if hour < 18 { return String(localized: "Good afternoon — here is everything running on this Mac") }
        return String(localized: "Good evening — here is everything running on this Mac")
    }

    // MARK: - Hero

    private var unhealthy: [String] { app.health.filter { $0.value == "unhealthy" }.map(\.key).sorted() }

    private var hero: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s + 2) {
            Group {
                if !unhealthy.isEmpty {
                    Label("\(unhealthy.count) need attention: \(unhealthy.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.critical.text)
                } else if running.isEmpty {
                    Label("Nothing running", systemImage: "moon.zzz").foregroundStyle(.secondary)
                } else {
                    Label("All healthy", systemImage: "checkmark.circle").foregroundStyle(Tone.positive.text)
                }
            }
            .font(.callout.weight(.semibold))
            Text(running.isEmpty ? "Ready when you are" : "\(running.count) apps running")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .contentTransition(.numericText())
                .animation(.smooth, value: running.count)
                .accessibilityIdentifier("overview.headline")
            Text(breakdown).font(.body).foregroundStyle(.secondary)
            let ports = running.flatMap { ContainerPresentation($0).ports }.filter { $0.url != nil }
            if !ports.isEmpty {
                FlowRow(spacing: DS.Spacing.s) {
                    ForEach(ports.prefix(8)) { EndpointPill(port: $0) }
                }
                .padding(.top, DS.Spacing.xs)
            } else if running.isEmpty {
                HStack {
                    Button("Run Container…") { app.requestRun() }
                    Button("Go to Compose") { app.section = .compose }
                }
                .padding(.top, DS.Spacing.xs)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: DS.Spacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.hero")
    }

    private var breakdown: String {
        let groups = ContainerList.group(running)
        let projects = groups.filter { $0.project != nil }.count
        let solo = groups.first { $0.project == nil }?.containers.count ?? 0
        let liveClusters = clusters.filter(\.isRunning).count
        let machines = runningMachines.count
        let parts = [projects == 0 ? nil : String(localized: "\(projects) compose projects"),
                     liveClusters == 0 ? nil : String(localized: "\(liveClusters) Kubernetes clusters"),
                     machines == 0 ? nil : String(localized: "\(machines) machines"),
                     solo == 0 ? nil : String(localized: "\(solo) on their own")]
            .compactMap { $0 }
        if parts.isEmpty { return String(localized: "Run a container, a compose app, a machine or a Kubernetes cluster.") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Usage

    private var usage: some View {
        let cores = app.systemStatus?.hostCPUs ?? ProcessInfo.processInfo.activeProcessorCount
        let cpu = running.compactMap { stats.series[$0.id]?.latestCPU }.reduce(0, +)
        let memory = running.compactMap { stats.series[$0.id]?.memoryUsage }.reduce(0, +)
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        // Top-aligned: a caption on two lines mustn't lift its ring.
        return HStack(alignment: .top, spacing: DS.Spacing.m) {
            Spacer(minLength: 0)
            UsageRing(value: !running.isEmpty && stats.series.isEmpty ? "—" : "\(Int(cpu.rounded()))%", caption: "CPU · \(cores) cores",
                      fraction: cpu / Double(max(1, cores) * 100),
                      accessibilityText: "CPU \(Int(cpu.rounded())) percent of \(cores) cores")
            Spacer(minLength: 0)
            UsageRing(value: !running.isEmpty && stats.series.isEmpty ? "—" : Format.memory(memory), caption: "Memory of \(Format.memory(physical))",
                      fraction: physical > 0 ? Double(memory) / Double(physical) : 0, color: DS.memory)
            Spacer(minLength: 0)
            diskRing
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .panel()
        .accessibilityIdentifier("overview.resources")
    }

    @ViewBuilder
    private var diskRing: some View {
        if let df = app.diskUsage {
            let total = df.images.sizeInBytes + df.containers.sizeInBytes + df.volumes.sizeInBytes
            let reclaimable = df.images.reclaimableInBytes + df.containers.reclaimableInBytes + df.volumes.reclaimableInBytes
            let capacity = Self.diskCapacity
            let ring = UsageRing(value: Format.bytes(total),
                                 caption: reclaimable > 0 ? "Disk · \(Format.bytes(reclaimable)) to free" : "Disk",
                                 fraction: capacity > 0 ? Double(total) / Double(capacity) : 0, color: DS.disk)
            if reclaimable > 1_000_000_000 {
                ring.cardAction(cornerRadius: DS.Radius.card) { confirmCleanup = true }.help("Free up disk space…")
            } else {
                ring
            }
        } else {
            UsageRing(value: "—", caption: "Disk", fraction: 0, color: DS.disk)
        }
    }

    /// The startup disk's size, for the disk ring.
    private static let diskCapacity: Int64 = {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }()

    // MARK: - Live map

    private var map: some View {
        let nodes = LiveMap.Node.nodes(containers: app.model.containers, clusters: clusters, health: app.health)
        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text("Everything, live").font(.title3.weight(.semibold))
                Text("Lines carry traffic as it happens · click anything to open it")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if nodes.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("What you run appears here, connected to this Mac."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LiveMap(nodes: nodes, open: open)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live map")
        .accessibilityIdentifier("overview.map")
    }

    private func open(_ node: LiveMap.Node) {
        switch node.kind {
        case .compose:
            app.revealProject = String(node.id.dropFirst("compose:".count))
            app.section = .compose
        case .cluster: app.section = .kubernetes
        case .machine: app.section = .machines
        case .container:
            app.revealContainer = String(node.id.dropFirst("container:".count))
            app.section = .containers
        }
    }

    // MARK: - Activity

    private struct Notice: Identifiable {
        let id: String
        let tone: Tone
        let title: String
        let message: String
        var actionTitle: String?
        var actionDisabled = false
        var action: (() -> Void)?
    }

    /// What needs doing, above what happened.
    private var notices: [Notice] {
        var notices: [Notice] = []
        for resource in [EngineResource.containers, .images] {
            if let error = app.model.snapshot.error(for: resource) {
                notices.append(Notice(id: "stale-\(resource.rawValue)", tone: .warning,
                                      title: resource.refreshFailedTitle,
                                      message: error.localizedDescription, actionTitle: String(localized: "Retry"),
                                      action: { Task { await app.model.refresh([resource]) } }))
            }
        }
        for image in userImages where app.imageUpdates.update(for: image) {
            let users = containers.filter { $0.configuration.image.reference == image.reference }
                .map { container in ContainerList.project(of: container).map { "\($0)/\(container.serviceName)" } ?? container.id }
            notices.append(Notice(id: "image-\(image.reference)", tone: .info,
                                  title: String(localized: "\(ActivityEntry.short(image.reference)) has an update"),
                                  message: users.isEmpty ? String(localized: "A newer image is published")
                                      : String(localized: "Used by \(users.joined(separator: ", "))"),
                                  actionTitle: pulling.contains(image.reference) ? String(localized: "Pulling…")
                                      : String(localized: "Pull Update"),
                                  actionDisabled: pulling.contains(image.reference),
                                  action: { pullUpdate(image) }))
        }
        if let df = app.diskUsage {
            let reclaimable = df.images.reclaimableInBytes + df.containers.reclaimableInBytes + df.volumes.reclaimableInBytes
            if reclaimable > 1_000_000_000 {
                notices.append(Notice(id: "reclaim", tone: .info, title: String(localized: "\(Format.bytes(reclaimable)) can be freed"),
                                      message: cleanupMessage, actionTitle: String(localized: "Clean Up…"),
                                      action: { confirmCleanup = true }))
            }
        }
        if let version = app.systemStatus?.apiServerVersion, let update = app.updates.update(over: version) {
            notices.append(Notice(id: "update", tone: .info, title: String(localized: "container \(update.version) is available"),
                                  message: String(localized: "You have \(version)"), actionTitle: String(localized: "Release Notes"),
                                  action: { NSWorkspace.shared.open(update.url) }))
        }
        if !app.model.isAgentBacked {
            notices.append(Notice(id: "agent", tone: .neutral, title: String(localized: "Background agent is off"),
                                  message: String(localized: "Containers are only watched while the app runs")))
        }
        return notices
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Activity").font(.title3.weight(.semibold))
            let notices = notices
            let entries = app.model.activity.prefix(8)
            if notices.isEmpty && entries.isEmpty {
                Text("Nothing has happened since Irekobox opened. Starts, stops and health changes show up here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notices) { notice in
                row(tone: notice.tone, title: notice.title, detail: notice.message) {
                    if let title = notice.actionTitle, let action = notice.action {
                        Button(title, action: action).controlSize(.small).padding(.top, DS.Spacing.xs)
                            .disabled(notice.actionDisabled)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    ForEach(entries) { entry in
                        row(tone: entry.tone, title: entry.title,
                            detail: "\(entry.detail) · \(Self.ago(entry.date, now: context.date))") { EmptyView() }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.activity")
    }

    private func row<Action: View>(tone: Tone, title: String, detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s + 2) {
            StatusDot(tone: tone).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "just now") }
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60)) min ago") }
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func pullUpdate(_ image: ContainerImage) {
        let reference = image.reference
        guard !pulling.contains(reference) else { return }
        pulling.insert(reference)
        Task {
            defer { pulling.remove(reference) }
            do {
                for try await _ in app.engine.pullImageWithProgress(reference, platform: "linux/arm64") {}
                await app.model.refresh([.images])
                if let pulled = app.model.images.first(where: { $0.reference == reference }) {
                    app.imageUpdates.pulled(pulled)
                }
            } catch {
                app.actionError = error.localizedDescription
            }
        }
    }

    private var cleanupMessage: String {
        let stopped = containers.filter { !$0.state.isRunning }.count
        let used = Set(app.model.containers.map { $0.configuration.image.reference })
        let unused = userImages.filter { !used.contains($0.reference) }.count
        return String(localized: "\(stopped) stopped containers, \(unused) unused images. Volumes are kept.")
    }
}

extension Container {
    /// The compose service it runs ("web"), else its name.
    var serviceName: String { configuration.labels["com.docker.compose.service"] ?? id }
}

/// Lays children out left to right, wrapping onto new lines (rows start at
/// the leading edge, unlike the centered `FlowLayout`).
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A place to open, as the Overview shows it: "localhost:8080 ↗".
private struct EndpointPill: View {
    let port: PortLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = port.url {
            Button {
                Milestone.openedInBrowser.reach()
                openURL(url)
            } label: {
                Text(verbatim: "\(url.host() ?? "localhost"):\(String(port.hostPort)) ↗")
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, DS.Spacing.s + 2)
                    .padding(.vertical, DS.Spacing.xs + 1)
                    .background(Capsule().fill(DS.accent.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Open \(url.absoluteString)")
            .accessibilityLabel("Open \(port.accessibilityDescription) in browser")
        }
    }
}

