import SwiftUI
import ContainerKit
import EngineCore

/// Settings › Troubleshoot: the `container` services' own logs, a restart,
/// and a diagnostics bundle to paste into a bug report.
struct TroubleshootPane: View {
    @Environment(AppState.self) private var app
    @State private var period = "10m"
    @State private var logs = ""
    @State private var isLoading = false
    @State private var showErrorsOnly = false
    @State private var copied = false
    @State private var isRestarting = false
    @State private var engineAction: EngineAction?
    @State private var showCheckup = false

    private static let periods: [(String, LocalizedStringResource)] = [("10m", "Last 10 minutes"), ("1h", "Last 1 hour"), ("1d", "Last 1 day")]
    /// Enough to scroll through; the full log is a `container system logs` away.
    private static let lineLimit = 3000

    private var lines: [String] {
        let all = logs.split(separator: "\n").filter { !$0.hasPrefix("Timestamp ") }
        let filtered = showErrorsOnly ? all.filter { $0.contains(" Error ") || $0.contains(" Fault ") } : all
        return filtered.suffix(Self.lineLimit).map(Self.compact)
    }

    /// "2026-10-25 23:42:19.155027-0700 0x9406cf8  Error  0x0  50975  0  container-core-images: msg"
    /// → "23:42:19  Error  container-core-images: msg". Other lines pass through.
    nonisolated static func compact(_ line: Substring) -> String {
        let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
        guard fields.count == 8, fields[2].hasPrefix("0x") else { return String(line) }
        let time = fields[1].prefix(8)
        let level = fields[3] == "Default" ? "" : "\(fields[3])  "
        return "\(time)  \(level)\(fields[7].trimmingCharacters(in: .whitespaces))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Picker("Show", selection: $showErrorsOnly) {
                    Text("Errors").tag(true)
                    Text("Everything").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The engine's errors, or all it logged")
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(Self.periods, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .accessibilityLabel("Reload logs")
            }

            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    Text(showErrorsOnly ? "No errors in this period." : "No log entries in this period.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(lines.joined(separator: "\n"))
                            .font(DS.Font.monoSmall)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Spacing.s)
                    }
                    .defaultScrollAnchor(.bottomLeading)
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.subtleFill))
            .accessibilityIdentifier("troubleshoot.logs")

            LearnNote("Something odd? **Run Checkup** looks at every container — ports nothing answers on, memory a VM keeps, slow shared folders — and tells you what to fix.")
            HStack(spacing: DS.Spacing.s) {
                Button("Run Checkup") { showCheckup = true }
                    .buttonStyle(.borderedProminent)
                    .help("Ports that don't answer, memory VMs keep, slow shared folders")
                    .accessibilityIdentifier("troubleshoot.checkup")
                Button(copied ? "Copied" : "Copy Report") { Task { await copyDiagnostics() } }
                    .buttonStyle(.automatic)
                    .help("Versions, engine status, configuration and recent errors, ready for a bug report")
                Button(isRestarting ? "Restarting…" : "Restart Engine") { engineAction = .restart }
                .buttonStyle(.automatic)
                .disabled(isRestarting)
                Spacer()
                Link("Report an issue with container", destination: URL(string: "https://github.com/apple/container/issues")!)
                    .font(.caption)
            }
        }
        .padding(DS.Spacing.l)
        .task(id: period) { await load() }
        .engineConfirmation($engineAction) { _ in
            Task {
                isRestarting = true
                await app.restartServices()
                isRestarting = false
                await load()
            }
        }
        .sheet(isPresented: $showCheckup) { AllContainersCheckup() }
        .accessibilityIdentifier("troubleshoot.pane")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            logs = try await app.engine.systemLogs(last: period)
        } catch {
            logs = String(localized: "Couldn't read the engine logs: \(error.localizedDescription)")
        }
    }

    private func copyDiagnostics() async {
        let info = Bundle.main.infoDictionary
        let properties: String
        do {
            properties = try await app.engine.systemProperties()
        } catch {
            properties = "unavailable: \(error.localizedDescription)"
        }
        let errors = logs.split(separator: "\n").filter { $0.contains(" Error ") || $0.contains(" Fault ") }.suffix(50)
        let report = """
        Irekobox \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        container \(app.systemStatus?.apiServerVersion ?? "unknown") · engine \(app.servicesRunning ? "running" : "stopped")
        Background agent: \(app.model.isAgentBacked ? "on" : "off")

        ## Configuration
        \(properties)
        ## Recent errors (last \(period))
        \(errors.isEmpty ? "none" : errors.joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        try? await Task.sleep(for: .seconds(2))
        copied = false
    }
}

/// Settings › Docker: the Docker Engine API socket served by the agent, and
/// how to point the docker CLI and other tools at it.
struct DockerCompatibilityPane: View {
    @Environment(AppState.self) private var app
    @State private var status: DockerSocketStatus?
    @State private var contextExists: Bool?
    @State private var working = false
    @State private var message: String?
    @State private var link: SocketLinkHelper.State = .off
    @State private var linking = false

    private var socketPath: String { status?.socketPath ?? DockerSocketStatus.defaultPath }

    var body: some View {
        Form {
            Section {
                Toggle("Serve the Docker API", isOn: Binding(
                    get: { app.dockerSocketEnabled },
                    set: { app.setDockerSocketEnabled($0); Task { await refresh(after: .milliseconds(400)) } }))
                    .disabled(!app.backgroundAgentEnabled)
                    .accessibilityIdentifier("docker.enable")
                LabeledContent("Status") {
                    HStack(spacing: DS.Spacing.xs) {
                        StatusDot(tone: tone)
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                if status?.listening == true {
                    LabeledContent("Socket") {
                        HStack(spacing: DS.Spacing.s) {
                            Text("unix://" + (socketPath as NSString).abbreviatingWithTildeInPath)
                                .font(DS.Font.monoSmall).textSelection(.enabled)
                            Button { copy("unix://\(socketPath)") } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy")
                                .accessibilityLabel("Copy socket address")
                        }
                    }
                }
            } footer: {
                Text(app.backgroundAgentEnabled
                     ? "The background helper serves docker, docker compose, Testcontainers and IDEs on a socket of their own, also with this window closed. Nothing uses it until you point a tool at it."
                     : "Needs the background helper (Settings › General).")
            }

            if status?.listening == true {
                Section {
                    LabeledContent("Docker context") {
                        if working {
                            ProgressView().controlSize(.small)
                        } else if contextExists == nil {
                            Text("docker CLI not found").foregroundStyle(.secondary)
                        } else if contextExists == true {
                            Button("Remove", role: .destructive) { Task { await removeContext() } }
                        } else {
                            Button("Create") { Task { await createContext() } }
                        }
                    }
                    usage("One command", "docker --context \(DockerContext.name) ps", copyLabel: "Copy one command")
                    usage("Every command in a shell", "export DOCKER_HOST=unix://\(socketPath)",
                          copyLabel: "Copy every command in a shell")
                    usage("Make it the default", "docker context use \(DockerContext.name)", copyLabel: "Copy make it the default")
                } header: {
                    Text("Use it")
                } footer: {
                    Text("Creating the context adds an entry to ~/.docker; your current default context stays as it is.")
                }
            }

            if status?.listening == true || link != .off {
                varRunSection
            }

            if status?.listening == true {
                supportSection
            }

            if let message {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text) }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("docker.pane")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var varRunSection: some View {
        Section {
            Toggle("Answer at /var/run/docker.sock", isOn: Binding(
                get: { link != .off },
                set: { on in Task { await setLink(on) } }))
                .disabled(linking)
                .accessibilityIdentifier("docker.varrun")
            if link != .off {
                LabeledContent("Status") {
                    HStack(spacing: DS.Spacing.xs) {
                        StatusDot(tone: linkTone)
                        Text(linkText).foregroundStyle(.secondary)
                    }
                }
            }
            if link == .needsApproval {
                Button("Open Login Items Settings") { SocketLinkHelper.openApproval() }
            }
        } header: {
            Text("Tools that ignore DOCKER_HOST")
        } footer: {
            Text("A small helper running as root points /var/run/docker.sock at this socket; you approve it once in System Settings › General › Login Items. Whatever the link pointed at before (usually Docker Desktop) is put back when you turn this off. If Docker Desktop takes the link back while it runs, it keeps it.")
        }
    }

    /// What the Docker API covers (Docker Engine API 1.24–1.56).
    private static let support: [(LocalizedStringResource, Bool, LocalizedStringResource)] = [
        ("Containers", true, "run, create, start/stop/kill, logs, stats, exec, attach, cp, export, top, restart policies"),
        ("Images", true, "pull, push, tag, rmi, inspect, history, save/load, search, prune"),
        ("Build", true, "docker build (BuildKit in a container; use --load), docker compose build"),
        ("Volumes and networks", true, "create, inspect, remove, prune; names between containers on a network"),
        ("Compose", true, "up, down, ps, logs, exec, build"),
        ("Events and disk usage", true, "docker events, docker system df"),
        ("Network changes after create", false, "networks are fixed when a container is created"),
        ("Host network, privileged devices, GPUs", false, "each container runs in its own virtual machine"),
        ("Swarm, plugins, secrets", false, "not available"),
    ]

    private var supportSection: some View {
        Section("What works") {
            ForEach(Self.support.indices, id: \.self) { index in
                let (name, works, detail) = Self.support[index]
                LabeledContent {
                    Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                } label: {
                    Label { Text(name) } icon: { Image(systemName: works ? "checkmark.circle.fill" : "minus.circle") }
                        .foregroundStyle(works ? Tone.positive.text : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var linkTone: Tone {
        switch link {
        case .on(.ours): return .positive
        case .needsApproval, .on: return .warning
        case .failed: return .critical
        case .off: return .inactive
        }
    }

    private var linkText: String {
        switch link {
        case .off: return String(localized: "Off")
        case .needsApproval: return String(localized: "Waiting for your approval in System Settings")
        case .on(.ours): return String(localized: "Points to Irekobox")
        case .on(.missing): return String(localized: "Being set up…")
        case .on(.other(let path)):
            let short = (path as NSString).abbreviatingWithTildeInPath
            return path.contains("/.docker/") ? String(localized: "Docker Desktop has it (\(short))") : String(localized: "Points to \(short)")
        case .failed(let text): return text
        }
    }

    private func setLink(_ on: Bool) async {
        linking = true
        defer { linking = false }
        link = on ? SocketLinkHelper.enable() : await SocketLinkHelper.disable()
    }

    private var tone: Tone {
        guard let status else { return .inactive }
        if status.listening { return .positive }
        return status.enabled ? .critical : .inactive
    }

    private var statusText: String {
        guard app.backgroundAgentEnabled else { return String(localized: "Background helper is off") }
        guard let status else { return String(localized: "Background helper not reachable") }
        if status.listening { return String(localized: "Listening") }
        if status.enabled { return status.error ?? String(localized: "Starting…") }
        return String(localized: "Off")
    }

    private func usage(_ title: LocalizedStringKey, _ command: String, copyLabel: LocalizedStringKey) -> some View {
        LabeledContent(title) {
            HStack(spacing: DS.Spacing.s) {
                Text(command).font(DS.Font.monoSmall).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button { copy(command) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .accessibilityLabel(copyLabel)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func refresh(after delay: Duration = .zero) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        status = await app.dockerSocketStatus()
        if !linking, case .failed = link {} else if !linking { link = SocketLinkHelper.state() }
        if status?.listening == true, contextExists == nil || !working {
            contextExists = await DockerContext.exists()
        }
    }

    private func createContext() async {
        working = true
        defer { working = false }
        do {
            try await DockerContext.create(socketPath: socketPath)
            message = nil
        } catch {
            message = String(localized: "Couldn't create the context: \(error.localizedDescription)")
        }
        contextExists = await DockerContext.exists()
    }

    private func removeContext() async {
        working = true
        defer { working = false }
        do {
            try await DockerContext.remove()
            message = nil
        } catch {
            message = String(localized: "Couldn't remove the context: \(error.localizedDescription)")
        }
        contextExists = await DockerContext.exists()
    }
}
