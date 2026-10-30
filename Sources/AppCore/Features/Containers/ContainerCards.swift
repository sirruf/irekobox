import SwiftUI
import ContainerKit

/// How the Containers screen lays out its items.
enum ContainersLayout: String {
    case cards, table
}

/// One container as a card: state and health, image, ways in, a CPU line
/// and what it uses, quick actions. The screen makes it selectable and opens
/// the container's page on a double-click.
struct ContainerCard: View {
    let row: ContainerRow
    let health: String?
    let busy: Bool
    /// In a project the card is titled by its service ("web").
    var inProject = false
    var updateAvailable = false
    let onTerminal: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    @State private var hovering = false

    private var container: Container { row.container }
    private var title: String { inProject ? container.serviceName : row.name }

    /// Amber while a health check is failing or still starting.
    private var lineTone: Tone {
        switch health {
        case "unhealthy": return .critical
        case "starting": return .warning
        default: return .info
        }
    }

    var body: some View {
        let presentation = row.presentation
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                StatusDot(tone: presentation.tone, size: 9)
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    .help(row.name)
                Spacer(minLength: DS.Spacing.xs)
                if let health, container.state.isRunning {
                    HealthBadge(status: health)
                } else if !container.state.isRunning {
                    Text(presentation.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(row.image)
                .font(DS.Font.monoSmall).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            reach(presentation)
                .frame(minHeight: 20, alignment: .leading)
            if container.state.isRunning {
                CPULine(samples: row.stats?.cpu ?? [], tone: lineTone)
                    .frame(height: 26)
                    .accessibilityHidden(true)
            }
            HStack(spacing: DS.Spacing.m) {
                if container.state.isRunning {
                    if let cpu = row.stats?.latestCPU {
                        Text("\(Int(cpu.rounded()))% CPU").monospacedDigit()
                            .accessibilityLabel("CPU \(Int(cpu.rounded())) percent")
                    }
                    if let stats = row.stats, stats.memoryUsage > 0 {
                        Text(Format.memory(stats.memoryUsage)).monospacedDigit()
                            .accessibilityLabel("Memory \(Format.memory(stats.memoryUsage))")
                    }
                    if let uptime = ContainerPresentation.uptime(container) {
                        Text("up \(uptime)")
                    }
                } else {
                    Text("Stopped")
                }
                Spacer(minLength: 0)
                actions.opacity(hovering || busy || !container.state.isRunning ? 1 : 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel - 2).fill(DS.raised)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel - 2)
            .strokeBorder(hovering ? DS.accent.opacity(0.6) : DS.separator.opacity(0.5), lineWidth: hovering ? 2 : 0.5))
        .opacity(container.state.isRunning ? 1 : 0.85)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel - 2))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(title), \(presentation.label)"))
        .accessibilityIdentifier("containers.card.\(row.id)")
    }

    /// Ports to open, else how other containers reach it.
    @ViewBuilder
    private func reach(_ presentation: ContainerPresentation) -> some View {
        if !presentation.ports.isEmpty || updateAvailable {
            HStack(spacing: DS.Spacing.xs + 2) {
                ForEach(presentation.ports.prefix(3)) { PortPill(port: $0, target: title) }
                if presentation.ports.count > 3 {
                    Text(verbatim: "+\(presentation.ports.count - 3)").font(.caption).foregroundStyle(.secondary)
                }
                if updateAvailable {
                    Text("Update available")
                        .font(.caption)
                        .foregroundStyle(DS.disk)
                        .padding(.horizontal, DS.Spacing.s).padding(.vertical, 2)
                        .background(Capsule().fill(DS.disk.opacity(0.12)))
                        .help("The registry has a newer image for this tag")
                }
            }
        } else if container.state.isRunning {
            let names = ContainerPresentation.localNames(container)
            Group {
                if let name = names.first {
                    Text("No ports published · reachable as \(Text(name).font(DS.Font.monoSmall))")
                } else {
                    Text("No ports published")
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("Not running").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if container.state.isRunning {
            Button(action: onTerminal) { Image(systemName: "terminal") }
                .help("Open a terminal in it")
                .accessibilityLabel("Terminal")
            Button(action: onStop) { Image(systemName: "stop.fill") }
                .help("Stop")
                .accessibilityLabel("Stop \(title)")
        } else {
            Button("Start", action: onStart)
                .buttonStyle(.link)
                .help("Start")
                .accessibilityLabel("Start \(title)")
        }
    }
}

/// A smooth line of recent CPU samples across the card.
private struct CPULine: View {
    let samples: [Double]
    var tone: Tone = .info

    var body: some View {
        GeometryReader { proxy in
            let values = samples.suffix(40)
            let top = max(10, values.max() ?? 0) * 1.15
            Path { path in
                guard values.count > 1 else {
                    path.move(to: CGPoint(x: 0, y: proxy.size.height - 1))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height - 1))
                    return
                }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: proxy.size.height - 1 - CGFloat(value / top) * (proxy.size.height - 2))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(tone.fill.opacity(values.count > 1 ? 1 : 0.3),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The dashed "Run Container…" card at the end of the list.
struct RunContainerCard: View {
    let run: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.xs + 2) {
            Label("Run Container…", systemImage: "plus").font(.callout.weight(.semibold)).foregroundStyle(DS.accent)
            Text("or paste a docker run command").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(minHeight: 110)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel - 2)
            .strokeBorder(DS.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel - 2))
        .cardAction(cornerRadius: DS.Radius.panel - 2, run)
        .accessibilityIdentifier("containers.runCard")
    }
}
