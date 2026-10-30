import SwiftUI
import ContainerKit

/// Settings › Engine: the `container` services, the defaults new containers
/// and the image builder get, the kernel, and disk usage.
struct EngineSettingsPane: View {
    @Environment(AppState.self) private var app
    @State private var confirmStop = false
    @State private var config: EngineConfig.Tables = [:]
    @State private var configError: String?
    /// A default was changed since the engine started: it applies on restart.
    @State private var needsRestart = false
    @State private var isRestarting = false
    /// Domains created with `container system dns create` (an admin step).
    @State private var dnsDomains: [String] = []
    @State private var newDomain = "test"
    @State private var domainBusy = false

    private static let memoryChoices = ["512mb", "1gb", "2gb", "4gb", "8gb", "16gb"]

    var body: some View {
        Form {
            engineSection
            if app.servicesRunning {
                defaultsSection
                domainSection
                builderSection
                kernelSection
            }
            if let df = app.diskUsage, app.servicesRunning {
                Section("Disk usage") {
                    dfRow("Images", df.images)
                    dfRow("Containers", df.containers)
                    dfRow("Volumes", df.volumes)
                }
            }
            if let error = app.lastError ?? configError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("system.form")
        .navigationTitle("Engine")
        .task { await app.model.observe([.system, .diskUsage]) }
        .task(id: app.servicesRunning) { await loadConfig() }
        .confirmationDialog("Stop the engine?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Engine", role: .destructive) { Task { await app.stopServices() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running containers stop until the engine is started again.")
        }
    }

    // MARK: - Sections

    private var engineSection: some View {
        Section("Engine") {
            LabeledContent("Status") {
                HStack(spacing: DS.Spacing.xs) {
                    StatusDot(tone: app.servicesRunning ? .positive : .critical)
                    Text(app.servicesRunning ? "Running" : "Stopped")
                }
            }
            .accessibilityIdentifier("system.status")
            if let version = app.systemStatus?.apiServerVersion {
                LabeledContent("Version") {
                    if let update = app.updates.update(over: version) {
                        HStack(spacing: DS.Spacing.s) {
                            Text(version)
                            Link("\(update.version) available", destination: update.url)
                        }
                    } else {
                        Text("\(version) · up to date")
                    }
                }
            }
            if let appRoot = app.systemStatus?.appRoot {
                LabeledContent("Data") {
                    Button((appRoot as NSString).abbreviatingWithTildeInPath) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: appRoot))
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Start the engine at login", isOn: Binding(
                    get: { app.startEngineAtLogin },
                    set: { app.setStartEngineAtLogin($0) }))
                    .disabled(!app.backgroundAgentEnabled)
                Text(app.backgroundAgentEnabled
                     ? "Containers with a restart policy (always, unless-stopped) come back with it."
                     : "Needs the background helper (General).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if isRestarting {
                    ProgressView().controlSize(.small)
                    Text("Restarting…").foregroundStyle(.secondary)
                } else if app.servicesRunning {
                    Button("Restart") { Task { await restart() } }
                    Button("Stop", role: .destructive) { confirmStop = true }
                } else {
                    Button("Start Engine") { Task { await app.startServices() } }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Refresh") { Task { await app.refreshSystem(); await loadConfig() } }
                    .accessibilityIdentifier("system.refresh")
            }
        }
    }

    private var defaultsSection: some View {
        Section {
            cpuPicker("CPUs", table: "container")
            memoryPicker("Memory", table: "container")
        } header: {
            Text("New containers")
        } footer: {
            restartNote("Used when `container run` doesn't set --cpus or --memory.")
        }
    }

    /// The domain set as default (`[dns] domain`) and whether it exists.
    private var activeDomain: String? { config["dns"]?["domain"].flatMap { $0.isEmpty ? nil : $0 } }

    private var domainSection: some View {
        Section {
            if let domain = activeDomain, dnsDomains.contains(domain) {
                LabeledContent("Domain") { Text(verbatim: ".\(domain)").font(DS.Font.monoSmall) }
                LabeledContent("Containers") { Text("http://<name>.\(domain)").font(DS.Font.monoSmall).textSelection(.enabled) }
                LabeledContent("Compose services") { Text("http://<service>.<project>.\(domain)").font(DS.Font.monoSmall).textSelection(.enabled) }
            } else if let existing = dnsDomains.first {
                LabeledContent("Domain .\(existing)") {
                    Button("Use It") { save("domain", in: "dns", value: "\"\(existing)\"") }
                }
            } else {
                HStack {
                    TextField("Domain", text: $newDomain)
                        .frame(maxWidth: 160)
                        .accessibilityIdentifier("engine.newDomain")
                    Button(domainBusy ? "Setting Up…" : "Set Up…") { Task { await createDomain() } }
                        .disabled(domainBusy || !Self.validDomain(newDomain))
                }
            }
        } header: {
            Text("Local domain")
        } footer: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                restartNote("Names for containers that this Mac's apps resolve — no published port needed. Setting up a domain asks for an administrator password once (it adds a resolver for the domain).")
            }
        }
        .task(id: app.servicesRunning) { await loadDomains() }
    }

    static func validDomain(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "." }
            && !text.hasPrefix(".") && !text.hasSuffix(".") && text != "local"
    }

    private func loadDomains() async {
        guard let data = try? await app.cli.data(["system", "dns", "ls"]) else { return }
        dnsDomains = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `container system dns create` needs root: macOS asks for the password.
    private func createDomain() async {
        domainBusy = true
        defer { domainBusy = false }
        let domain = newDomain
        let binary = URL(fileURLWithPath: Settings.shared.binaryPath).resolvingSymlinksInPath().path
        // It runs as root: only Apple's signed, root-owned `container`.
        guard Self.validDomain(domain), ContainerInstaller.isTrustedBinary(at: binary) else {
            configError = String(localized: "Couldn't create the domain: \(binary) isn't Apple's signed container CLI in a folder only root can change. Set the path in Settings › General.")
            return
        }
        let script = "do shell script \"'\(binary)' system dns create '\(domain)'\" with administrator privileges"
        let error: String? = await Task.detached {
            var info: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&info)
            guard let info, (info[NSAppleScript.errorNumber] as? Int) != -128 else { return nil }   // -128: cancelled
            return info[NSAppleScript.errorMessage] as? String ?? String(localized: "failed")
        }.value
        if let error {
            configError = String(localized: "Couldn't create the domain: \(error)")
            return
        }
        await loadDomains()
        if dnsDomains.contains(domain) { save("domain", in: "dns", value: "\"\(domain)\"") }
    }

    private var builderSection: some View {
        Section {
            cpuPicker("CPUs", table: "build")
            memoryPicker("Memory", table: "build")
            Toggle("Build amd64 images with Rosetta", isOn: Binding(
                get: { config["build"]?["rosetta"] != "false" },
                set: { save("rosetta", in: "build", value: $0 ? "true" : "false") }))
        } header: {
            Text("Image builder")
        } footer: {
            restartNote("Resources of the BuildKit VM used by `container build`.")
        }
    }

    @ViewBuilder
    private var kernelSection: some View {
        if let kernel = config["kernel"], let path = kernel["binaryPath"] {
            Section("Kernel") {
                LabeledContent("Image") {
                    Text((path as NSString).lastPathComponent).font(DS.Font.monoSmall).textSelection(.enabled)
                }
                if let url = kernel["url"], let link = URL(string: url) {
                    LabeledContent("Source") {
                        Link(link.host() ?? url, destination: link).font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Controls

    private func cpuPicker(_ title: LocalizedStringKey, table: String) -> some View {
        let cores = app.systemStatus?.hostCPUs ?? ProcessInfo.processInfo.activeProcessorCount
        let current = Int(config[table]?["cpus"] ?? "") ?? 0
        return Picker(title, selection: Binding(
            get: { current },
            set: { save("cpus", in: table, value: "\($0)") })) {
            if current == 0 { Text("Default").tag(0) }
            ForEach(Array(1...max(cores, current)), id: \.self) { Text("\($0)").tag($0) }
        }
    }

    private func memoryPicker(_ title: LocalizedStringKey, table: String) -> some View {
        let raw = config[table]?["memory"] ?? ""
        // "2048mb" is the "2gb" choice, not a second "2 GB" entry.
        let current = Self.memoryChoices.first { EngineConfig.bytes($0) == EngineConfig.bytes(raw) } ?? raw
        let choices = Self.memoryChoices.contains(current) || current.isEmpty
            ? Self.memoryChoices : [current] + Self.memoryChoices
        let hostMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        return Picker(title, selection: Binding(
            get: { current },
            set: { save("memory", in: table, value: "\"\($0)\"") })) {
            if current.isEmpty { Text("Default").tag("") }
            ForEach(choices, id: \.self) { choice in
                let bytes = EngineConfig.bytes(choice) ?? 0
                Text(Format.memory(bytes)).tag(choice)
                    .disabled(bytes > hostMemory / 2 && choice != current)
            }
        }
    }

    private func restartNote(_ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(text)
            if needsRestart {
                HStack(spacing: DS.Spacing.s) {
                    Text("Saved to ~/.config/container/config.toml. Applies when the engine restarts.")
                    Button("Restart Now") { Task { await restart() } }
                        .buttonStyle(.link)
                        .disabled(isRestarting)
                }
                .foregroundStyle(Tone.info.text)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func dfRow(_ label: LocalizedStringKey, _ entry: SystemDiskUsage.Entry) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(Format.bytes(entry.sizeInBytes)).monospacedDigit()
                if entry.reclaimableInBytes > 0 {
                    Text("· \(Format.bytes(entry.reclaimableInBytes)) reclaimable")
                        .font(.caption).foregroundStyle(Tone.warning.text)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadConfig() async {
        guard app.servicesRunning else { return }
        do {
            let effective = EngineConfig.parse(try await app.engine.systemProperties())
            let saved = EngineConfig.parse((try? String(contentsOf: EngineConfig.userFile, encoding: .utf8)) ?? "")
            config = EngineConfig.overlay(saved, on: effective)
            needsRestart = config != effective
            configError = nil
        } catch {
            configError = String(localized: "Couldn't read the engine configuration: \(error.localizedDescription)")
        }
    }

    private func save(_ key: String, in table: String, value: String) {
        do {
            try EngineConfig.write(key, in: table, value: value)
            // Reflect it now; the listing shows it after the restart.
            config[table, default: [:]][key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            needsRestart = true
            configError = nil
        } catch {
            configError = String(localized: "Couldn't save ~/.config/container/config.toml: \(error.localizedDescription)")
        }
    }

    private func restart() async {
        isRestarting = true
        await app.stopServices()
        await app.startServices()
        isRestarting = false
        needsRestart = false
        await loadConfig()
    }
}
