import SwiftUI
import Observation
import ContainerKit

/// The last few lines a container wrote, followed live.
@MainActor
@Observable
final class LogTail {
    private(set) var lines: [String] = []
    let keep: Int

    init(keep: Int = 6) {
        self.keep = keep
    }

    /// Follow `id` until the calling task is cancelled.
    func follow(engine: any ContainerEngine, id: String) async {
        lines = []
        do {
            for try await line in engine.containerLogs(id, follow: true) {
                lines.append(line)
                if lines.count > keep { lines.removeFirst(lines.count - keep) }
            }
        } catch {
            // The tail is a glance; the Logs tab reports stream errors.
        }
    }
}

/// The selected service on the compose map: how it's doing, its latest
/// output, what it reaches and what reaches it, and what to do with it.
struct ServiceInspector: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    let service: ComposeService
    /// Every service of the project, to say who uses this one.
    let services: [ComposeService]
    let stats: LiveStats.Series?
    let health: String?

    @State private var tail = LogTail()
    @State private var busy = false

    private var container: Container? { service.containers.first }
    private var running: Bool { container?.state.isRunning == true }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header
                if let url = service.ports.lazy.compactMap(\.url).first, running {
                    Button { openURL(url) } label: {
                        HStack {
                            Text(url.absoluteString).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                        }
                        .padding(.horizontal, DS.Spacing.m)
                        .padding(.vertical, DS.Spacing.s)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.accent.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.accent)
                    .help("Open in the browser")
                }
                if running { usage }
                if container != nil { latestLog }
                reaches
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            actions.padding(DS.Spacing.l)
        }
        .task(id: "\(container?.id ?? "") \(running)") {
            guard let container, running else { return }
            await tail.follow(engine: app.engine, id: container.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(service.name) details")
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(service.tone.fill)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(service.tone.fill.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.title3.weight(.semibold))
                Text(statusLine).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// "Running · healthy · up 3h"
    private var statusLine: String {
        var parts = [service.stateLabel]
        if let health { parts.append(health) }
        if running, let started = container?.startedDate {
            parts.append(String(localized: "up \(Format.duration(Date().timeIntervalSince(started)))", comment: "Uptime, e.g. up 3h"))
        }
        return parts.joined(separator: " · ")
    }

    private var usage: some View {
        HStack(spacing: DS.Spacing.m) {
            figure("CPU", stats?.latestCPU.map { "\(Int($0.rounded()))%" } ?? "—")
            figure("Memory", stats.map { Format.memory($0.memoryUsage) } ?? "—")
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.subtleFill))
        .accessibilityElement(children: .combine)
    }

    private var latestLog: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Latest log").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Group {
                if tail.lines.isEmpty {
                    (running ? Text("No output yet") : Text("Not running")).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(tail.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .foregroundStyle(LogBuffer.level(of: line) == .error ? Color(red: 1, green: 0.62, blue: 0.3)
                                                 : Color(white: 0.85))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
            .font(DS.Font.monoSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(Color(red: 0.11, green: 0.12, blue: 0.14)))
            .foregroundStyle(Color(white: 0.85))
            .textSelection(.enabled)
        }
    }

    /// Lines in and out of the service, in words.
    private var reaches: some View {
        let users = services.filter { $0.dependsOn.contains(service.name) }.map(\.name)
        return VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Reaches").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(service.dependsOn, id: \.self) { dependency in
                reachRow("arrow.right", "Needs **\(dependency)**, by the name `\(dependency)`")
            }
            ForEach(service.ports) { access in
                if case .port(let port, _) = access {
                    reachRow("arrow.left", "This Mac on `\(String(port.hostPort))` → `\(String(port.containerPort))`")
                }
            }
            ForEach(users, id: \.self) { user in
                reachRow("arrow.left", "Used by **\(user)**")
            }
            ForEach(service.names) { access in
                reachRow("globe", "From this Mac as `\(access.title)`")
            }
            if service.dependsOn.isEmpty && service.ports.isEmpty && users.isEmpty && service.names.isEmpty {
                Text("Nothing is wired to it.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func reachRow(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.secondary) }
    }

    private var actions: some View {
        VStack(spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) { quickActions }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
            if let container {
                Button { app.openContainer(container.id) } label: {
                    Label("Open Container Page", systemImage: "arrow.up.forward.square")
                        .frame(maxWidth: .infinity)
                }
                .help("Everything about \(container.id): logs, stats, files and settings")
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var quickActions: some View {
        if let container {
            if running {
                OpenTerminalWindowButton(target: TerminalTarget(
                    title: container.id, command: ConsoleShell.auto.displayCommand(containerID: container.id),
                    arguments: ConsoleShell.auto.arguments(containerID: container.id)),
                    title: "Terminal", systemImage: "terminal")
            }
            Button { app.openContainer(container.id, tab: .logs) } label: {
                Label("Logs", systemImage: "text.alignleft").frame(maxWidth: .infinity)
            }
            if running {
                Button { restart(container.id) } label: {
                    Label("Restart", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .disabled(busy)
            }
        }
    }

    private func restart(_ id: String) {
        Task {
            busy = true
            await app.perform {
                app.noteHandAction(stopped: true, [id])
                try await app.engine.stopContainer(id)
                try await app.engine.startContainer(id)
                app.noteHandAction(stopped: false, [id])
            }
            busy = false
        }
    }
}
