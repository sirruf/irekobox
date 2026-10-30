import SwiftUI
import ContainerKit

/// The right-hand pane for the selected container: how to reach it, what it
/// uses, and how it's configured.
struct ContainerInspector: View {
    let container: Container
    let stats: LiveStats.Series?
    let isBusy: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onOpenDetail: () -> Void
    /// The detail view has its own header; the inspector shows one.
    var showsHeader = true

    @Environment(\.openURL) private var openURL

    private var presentation: ContainerPresentation { ContainerPresentation(container) }
    private var config: Container.Configuration { container.configuration }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                if showsHeader { header }
                reachIt
                if container.state.isRunning { CheckupSection(container: container) }
                if container.state.isRunning { resources }
                mounts
                environment
                details
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("containers.inspector")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                Text(container.id).font(.title3.weight(.bold)).textSelection(.enabled)
                StatusPill(tone: presentation.tone, label: presentation.label)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: DS.Spacing.s) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if container.state.isRunning {
                    Button("Stop", action: onStop)
                    Button("Restart", action: onRestart)
                } else {
                    Button("Start", action: onStart).buttonStyle(.borderedProminent)
                }
                Button("Logs", action: onOpenDetail)
            }
            .controlSize(.small)
        }
    }

    private var localNames: [String] { ContainerPresentation.localNames(container) }

    /// The container port a name should open: the first published one.
    private var firstPort: Int? { config.publishedPorts?.first?.containerPort }

    static func portSuffix(_ port: Int?) -> String {
        guard let port, port != 80 else { return "" }
        return ":\(port)"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let project = ContainerList.project(of: container) { parts.append(project) }
        parts.append(container.imageShortName)
        if let uptime = ContainerPresentation.uptime(container) { parts.append(String(localized: "up \(uptime)")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var reachIt: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader("Reach it")
            if presentation.ports.isEmpty {
                Text(container.state.isRunning ? "No ports published — reachable from other containers only."
                                               : "No ports published.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(presentation.ports) { port in
                if let url = port.url {
                    Button { openURL(url) } label: {
                        HStack {
                            Text(url.absoluteString).font(DS.Font.monoSmall)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .padding(.horizontal, DS.Spacing.m)
                        .padding(.vertical, DS.Spacing.s)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.separator))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .help("Open in browser")
                } else {
                    KeyValueRow(port.label, "→ \(port.containerPort)/\(port.proto)", monospaced: true)
                }
            }
            ForEach(container.status.networks, id: \.self) { network in
                if let address = network.ipv4Address {
                    KeyValueRow("IP on \(network.network ?? String(localized: "network"))",
                                address.split(separator: "/").first.map(String.init) ?? address,
                                monospaced: true)
                }
            }
            // Under a local DNS domain this Mac resolves these names to the
            // container itself: any port it listens on, published or not.
            ForEach(localNames, id: \.self) { name in
                if container.state.isRunning, let url = URL(string: "http://\(name)\(Self.portSuffix(firstPort))") {
                    Button { openURL(url) } label: {
                        HStack {
                            Text(url.absoluteString).font(DS.Font.monoSmall)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .help("Open by name (no published port needed)")
                } else {
                    KeyValueRow("Name", name, monospaced: true)
                }
            }
            if localNames.isEmpty, let hostname = config.networks.first?.options?.hostname {
                KeyValueRow("Hostname", hostname, monospaced: true)
            }
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            SectionHeader("Resources")
            if let stats, let cpu = stats.latestCPU {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack {
                        Text("CPU")
                        Spacer()
                        Text("\(Int(cpu.rounded()))% · \(container.cpus) CPUs").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Sparkline(samples: stats.cpu, maxValue: max(100, stats.cpu.max() ?? 0))
                        .frame(height: 32)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("CPU")
                .accessibilityValue("\(Int(cpu.rounded())) percent")
                MetricBar(title: "Memory",
                          value: String(localized: "\(Format.memory(stats.memoryUsage)) of \(Format.memory(stats.memoryLimit))"),
                          fraction: stats.memoryFraction)
            } else {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var mounts: some View {
        let mounts = config.mounts ?? []
        if !mounts.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                SectionHeader("Mounts")
                ForEach(mounts, id: \.self) { mount in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: "\(mount.volumeName ?? mount.source ?? "?") → \(mount.destination)")
                            .font(DS.Font.monoSmall)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        if mount.volumeName != nil {
                            Text("volume").font(.caption).foregroundStyle(.secondary)
                        } else if let source = mount.source {
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source)])
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var environment: some View {
        let entries = config.initProcess.environment.filter { !$0.hasPrefix("PATH=") }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                SectionHeader("Environment")
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(entries, id: \.self) { entry in
                        Text(ContainerList.maskedEnvironment(entry))
                            .font(DS.Font.monoSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader("Configuration")
            KeyValueRow("Image", config.image.reference, monospaced: true)
            KeyValueRow("Platform", "\(config.platform.os)/\(config.platform.architecture)\(config.rosetta ? " · Rosetta" : "")")
            KeyValueRow("Resources", String(localized: "\(container.cpus) CPUs · \(Format.memory(container.memoryInBytes))"))
            KeyValueRow("Created", Format.dateTime(fromISO: config.creationDate))
            let labels = config.labels.filter { !ContainerList.projectLabels.contains($0.key) }
            ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                KeyValueRow(key, value, monospaced: true)
            }
        }
    }
}
