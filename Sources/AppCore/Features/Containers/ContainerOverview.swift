import SwiftUI
import ContainerKit

/// The Overview tab of a container's page: who it is and where to open it,
/// what it uses right now next to its live log, then how to reach it, its
/// health and storage, and the rest of its configuration.
struct ContainerOverview: View {
    let container: Container
    let stats: LiveStats.Series?
    let health: String?
    var openLogs: () -> Void = {}
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    private var config: Container.Configuration { container.configuration }
    private var presentation: ContainerPresentation { ContainerPresentation(container) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l + DS.Spacing.xs) {
                hero
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Spacing.l) {
                        usage.frame(minWidth: 460)
                        LiveLogPanel(id: container.id, running: container.state.isRunning, openLogs: openLogs)
                            .frame(minWidth: 260, maxWidth: 420)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: DS.Spacing.l) {
                        usage
                        LiveLogPanel(id: container.id, running: container.state.isRunning, openLogs: openLogs)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: DS.Spacing.l, alignment: .top)],
                          alignment: .leading, spacing: DS.Spacing.l) {
                    OverviewCard("Reach it", systemImage: "network") { reach }
                    if let check = healthCheck {
                        OverviewCard("Health", systemImage: "heart.text.square") { healthBody(check) }
                    }
                    OverviewCard("Storage", systemImage: "externaldrive") { storage }
                    OverviewCard("Process", systemImage: "terminal") { process }
                    let environment = config.initProcess.environment.filter { !$0.hasPrefix("PATH=") }
                    if !environment.isEmpty {
                        OverviewCard("Environment", systemImage: "list.bullet.rectangle") { environmentBody(environment) }
                    }
                    OverviewCard("Configuration", systemImage: "slider.horizontal.3") { configuration }
                    if container.state.isRunning {
                        OverviewCard("Checkup", systemImage: "stethoscope") {
                            CheckupSection(container: container, showsTitle: false)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.xl + 4)
            .padding(.vertical, DS.Spacing.xl)
        }
        .background(DS.canvas)
        .accessibilityIdentifier("containerDetail.overview")
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: DS.Spacing.l + 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(presentation.tone.fill.opacity(0.14))
                Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(presentation.tone.fill)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s + 2) {
                    Text(container.id).font(.system(size: 28, weight: .bold)).tracking(-0.5)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 0) {
                        Text(presentation.label)
                        if let health, container.state.isRunning { Text(verbatim: " · \(HealthBadge.label(health))") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTone.text)
                    .padding(.horizontal, DS.Spacing.s + 1).padding(.vertical, 3)
                    .background(Capsule().fill(statusTone.fill.opacity(0.12)))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("containerDetail.statusBadge")
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Spacing.m)
            if let url = presentation.ports.first?.url, container.state.isRunning {
                Button {
                    Milestone.openedInBrowser.reach()
                    openURL(url)
                } label: {
                    HStack(spacing: DS.Spacing.s + 2) {
                        Text(verbatim: "\(url.host() ?? "localhost"):\(String(presentation.ports[0].hostPort))").font(.system(.callout, design: .monospaced).weight(.semibold))
                        Image(systemName: "arrow.up.right").font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Spacing.l + 2).padding(.vertical, DS.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: 14).fill(DS.accent))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .help("Open \(url.absoluteString)")
                .accessibilityLabel("Open \(url.absoluteString)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("containerDetail.header")
    }

    private var statusTone: Tone {
        switch health {
        case "unhealthy" where container.state.isRunning: return .critical
        case "starting" where container.state.isRunning: return .warning
        default: return presentation.tone
        }
    }

    /// "shop · nginx:alpine · up 3 h 12 min · restarts on failure".
    private var subtitle: String {
        var parts: [String] = []
        if let project = ContainerList.project(of: container) { parts.append(project) }
        parts.append(container.imageShortName)
        if let uptime = ContainerPresentation.uptime(container) { parts.append(String(localized: "up \(uptime)")) }
        switch config.labels["com.irekobox.docker.restart"] {
        case "always": parts.append(String(localized: "always restarts"))
        case "unless-stopped": parts.append(String(localized: "restarts unless stopped"))
        case let policy? where policy.hasPrefix("on-failure"): parts.append(String(localized: "restarts on failure"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Usage

    private var usage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xl) {
                bigNumber("CPU", stats?.latestCPU.map { "\(Int($0.rounded()))" } ?? "—", unit: "%")
                bigNumber("Memory", stats.map { Format.memory($0.memoryUsage) } ?? "—", unit: "")
                bigNumber("Network in / out",
                          stats.map { "\(Format.rate($0.networkIn)) / \(Format.rate($0.networkOut))" } ?? "—", unit: "")
                Spacer(minLength: 0)
                Text("Last minute").font(.caption).foregroundStyle(.secondary)
            }
            if container.state.isRunning {
                AreaChart(samples: stats?.cpu ?? [])
                    .frame(height: 150)
                    .accessibilityLabel("CPU over the last minute")
                    .accessibilityValue(cpuSummary)
            } else {
                Text("Not running — start it to see what it uses.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
            if let stats, stats.memoryLimit > 0 {
                Text("Memory limit \(Format.memory(stats.memoryLimit)) · \(container.cpus) CPUs")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
    }

    private var cpuSummary: String {
        guard let samples = stats?.cpu, let low = samples.min(), let high = samples.max() else { return String(localized: "No samples yet") }
        return String(localized: "between \(Int(low.rounded())) and \(Int(high.rounded())) percent")
    }

    private func bigNumber(_ title: LocalizedStringKey, _ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                if !unit.isEmpty && value != "—" { Text(unit).font(.system(size: 16, weight: .bold)) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reach it

    @ViewBuilder
    private var reach: some View {
        let names = ContainerPresentation.localNames(container)
        if presentation.ports.isEmpty && names.isEmpty {
            Text(container.state.isRunning ? "No ports published: other containers on its networks reach it."
                                           : "No ports published.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(presentation.ports) { port in
            if let url = port.url {
                linkRow(url.absoluteString, detail: "→ \(port.containerPort)/\(port.proto)", url: url,
                        live: container.state.isRunning)
            } else {
                KeyValueRow(port.label, "→ \(port.containerPort)/\(port.proto)", monospaced: true)
            }
        }
        ForEach(names, id: \.self) { name in
            let port = config.publishedPorts?.first?.containerPort
            let suffix = port == nil || port == 80 ? "" : ":\(port!)"
            if let url = URL(string: "http://\(name)\(suffix)") {
                linkRow(url.absoluteString, detail: String(localized: "by name, any port"), url: url, live: container.state.isRunning)
            }
        }
        if container.state.isRunning {
            Divider()
            ForEach(container.status.networks, id: \.self) { network in
                if let address = network.ipv4Address?.split(separator: "/").first.map(String.init) {
                    HStack {
                        Text(network.network ?? String(localized: "network")).foregroundStyle(.secondary)
                        Spacer()
                        Text(address).font(DS.Font.mono).textSelection(.enabled)
                        CopyButton(value: address)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func linkRow(_ title: String, detail: String, url: URL, live: Bool) -> some View {
        Button { openURL(url) } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "arrow.up.right.square.fill").foregroundStyle(live ? DS.accent : .secondary)
                Text(title).font(DS.Font.mono).foregroundStyle(live ? DS.accent : .secondary)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.accent.opacity(live ? 0.08 : 0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!live)
        .help(live ? "Open \(url.absoluteString)" : "It isn't running")
    }

    // MARK: - Resources

    @ViewBuilder
    private var resources: some View {
        if container.state.isRunning, let stats, let cpu = stats.latestCPU {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(cpu.rounded()))%").font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("CPU").foregroundStyle(.secondary)
                Spacer()
                Text("of \(container.cpus) CPUs").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Sparkline(samples: stats.cpu, maxValue: max(100, stats.cpu.max() ?? 0))
                .frame(height: 48)
            MetricBar(title: "Memory",
                      value: String(localized: "\(Format.memory(stats.memoryUsage)) of \(Format.memory(stats.memoryLimit))"),
                      fraction: stats.memoryFraction)
        } else if container.state.isRunning {
            Text("Measuring…").font(.callout).foregroundStyle(.secondary)
        } else {
            KeyValueRow("Limits", String(localized: "\(container.cpus) CPUs · \(Format.memory(container.memoryInBytes))"))
        }
    }

    // MARK: - Health

    /// The health check it runs (from the compose file or Docker API).
    private var healthCheck: String? {
        guard let text = config.labels["com.irekobox.docker.healthcheck"],
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let test = object["Test"] as? [String] else { return nil }
        if test.first == "CMD-SHELL" { return test.dropFirst().joined(separator: " ") }
        if test.first == "CMD" { return test.dropFirst().joined(separator: " ") }
        return test.joined(separator: " ")
    }

    @ViewBuilder
    private func healthBody(_ check: String) -> some View {
        HStack {
            if let health { HealthBadge(status: health) } else {
                Text(container.state.isRunning ? "Waiting for the first check" : "Not running")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        Text(check).font(DS.Font.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Storage

    @ViewBuilder
    private var storage: some View {
        let mounts = config.mounts ?? []
        if mounts.isEmpty {
            Text("Nothing mounted: its files live and go with the container.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(mounts, id: \.self) { mount in
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: mount.volumeName != nil ? "externaldrive.fill" : "folder.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mount.volumeName ?? (mount.source.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "?"))
                        .font(DS.Font.monoSmall).lineLimit(1).truncationMode(.middle)
                    Group {
                        if mount.isReadOnly {
                            Text("→ \(mount.destination) · read-only")
                        } else {
                            Text(verbatim: "→ \(mount.destination)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mount.volumeName == nil, let source = mount.source {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)]) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    // MARK: - Process

    @ViewBuilder
    private var process: some View {
        let command = ([config.initProcess.executable] + config.initProcess.arguments).joined(separator: " ")
        HStack(alignment: .top) {
            Text(command).font(DS.Font.monoSmall).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            CopyButton(value: command)
        }
        .padding(DS.Spacing.s)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.subtleFill))
        KeyValueRow("Working directory", config.initProcess.workingDirectory, monospaced: true)
        KeyValueRow("User", user)
        if let restart = config.labels["com.irekobox.docker.restart"] {
            KeyValueRow("Restart", restart)
        }
    }

    private var user: String {
        switch config.initProcess.user {
        case .raw(let name)?: return name
        case .id(let uid, let gid)?: return uid == 0 ? "root" : "uid \(uid), gid \(gid)"
        case nil: return "root"
        }
    }

    // MARK: - Environment

    private func environmentBody(_ entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(entries, id: \.self) { entry in
                let masked = ContainerList.maskedEnvironment(entry)
                let parts = masked.split(separator: "=", maxSplits: 1).map(String.init)
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                    Text(parts.first ?? masked).font(DS.Font.monoSmall.weight(.semibold))
                    Text(parts.count > 1 ? parts[1] : "").font(DS.Font.monoSmall).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configuration: some View {
        KeyValueRow("Image", config.image.reference, monospaced: true)
        KeyValueRow("Platform", "\(config.platform.os)/\(config.platform.architecture)\(config.rosetta ? " · Rosetta" : "")")
        KeyValueRow("Limits", String(localized: "\(container.cpus) CPUs · \(Format.memory(container.memoryInBytes))"))
        KeyValueRow("Created", Format.dateTime(fromISO: config.creationDate))
        let labels = config.labels.filter { !$0.key.hasPrefix("com.irekobox.") && !$0.key.hasPrefix("com.docker.compose.") }
        if !labels.isEmpty {
            DisclosureGroup("Labels (\(labels.count))") {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        KeyValueRow(key, value, monospaced: true)
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
            .font(.callout)
        }
    }
}

/// A card on a detail page: an icon, a title and its content.
struct OverviewCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panel()
    }
}

/// CPU over time as a filled line, scaled to its own peak (at least 10%).
struct AreaChart: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { proxy in
            let values = samples.count > 1 ? samples : [0, 0]
            let top = max(10, values.max() ?? 0) * 1.15
            let step = proxy.size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - CGFloat(value / top)))
            }
            let line = Path { path in
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            ZStack {
                Path { path in
                    path.addPath(line)
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(DS.accent.opacity(0.12))
                line.stroke(DS.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .animation(.smooth, value: samples)
        }
        .accessibilityElement(children: .ignore)
    }
}

/// The last lines of a container's output, live, on a dark panel.
struct LiveLogPanel: View {
    let id: String
    let running: Bool
    let openLogs: () -> Void
    @Environment(AppState.self) private var app
    @State private var model = LogViewerModel(capacity: 200)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Text("LIVE LOG").font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(Color(white: 0.63))
                Spacer()
                Button("Open Logs", action: openLogs).buttonStyle(.link).font(.caption)
                    .foregroundStyle(DS.dynamic(light: 0x6CB6FF, dark: 0x6CB6FF))
            }
            let entries = model.buffer.entries.suffix(8)
            if entries.isEmpty {
                Text(running ? "Waiting for output…" : "Not running.")
                    .font(DS.Font.monoSmall).foregroundStyle(Color(white: 0.63))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        Text(entry.text)
                            .font(DS.Font.monoSmall)
                            .foregroundStyle(entry.level == .info ? Color(white: 0.85)
                                             : entry.level == .warning ? Color(red: 1, green: 0.7, blue: 0.25)
                                             : Color(red: 1, green: 0.45, blue: 0.4))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l + DS.Spacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(Color(red: 0.114, green: 0.122, blue: 0.137)))
        .environment(\.colorScheme, .dark)
        .task(id: id) { await model.stream(engine: app.engine, id: id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live log")
    }
}

/// Copies `value` to the pasteboard.
struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
        .accessibilityLabel("Copy \(value)")
    }
}
