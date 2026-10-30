import SwiftUI
import ContainerKit

/// Container machines: Linux VMs with your account and home folder, for a
/// shell rather than a service.
struct MachinesView: View {
    @Environment(AppState.self) private var app
    @State private var model: MachinesModel?
    @State private var selection: String?
    @State private var showCreate = false
    @State private var deleteLeftover: Container?

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        // Empty states and loading sit on the canvas too, not on the window's white.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.canvas)
        .navigationTitle("Machines")
        .navigationSubtitle("Linux systems with your account and home folder")
        .onAppear {
            guard model == nil else { return }
            let model = MachinesModel(cli: app.cli)
            model.onChange = { [app] in Task { await app.model.refresh([.containers, .images]) } }
            self.model = model
        }
        .task(id: model == nil) {
            guard let model else { return }
            while !Task.isCancelled {
                await model.refresh()
                if selection == nil { selection = model.machines.first(where: { $0.default == true })?.id ?? model.machines.first?.id }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Machine…") { showCreate = true }
                    .buttonStyle(.borderedProminent)
                    .help("Create a machine")
                    .accessibilityIdentifier("machines.new")
            }
        }
        .confirmationDialog("Delete \(deleteLeftover?.id ?? "")?", isPresented: Binding(
            get: { deleteLeftover != nil }, set: { if !$0 { deleteLeftover = nil } }), titleVisibility: .visible,
                            presenting: deleteLeftover) { container in
            Button("Delete", role: .destructive) {
                Task { await app.perform { try await app.engine.deleteContainer(container.id, force: true) } }
            }
        } message: { _ in
            Text("The VM stops and its disk is deleted. Files in your home folder stay.")
        }
        .sheet(isPresented: $showCreate) {
            if let model {
                NewMachineSheet(model: model) { name in selection = name }
            }
        }
    }

    /// Machine VMs the engine runs but `container machine` no longer lists,
    /// e.g. after a create that was cut short.
    private func leftovers(_ model: MachinesModel) -> [Container] {
        guard model.loaded else { return [] }
        let known = Set(model.machines.map(\.id))
        return app.model.containers.filter { $0.isMachine && !known.contains($0.machineName ?? $0.id) }
    }

    @ViewBuilder
    private func leftoverPanel(_ model: MachinesModel) -> some View {
        let leftovers = leftovers(model)
        if !leftovers.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Label("Machine VMs without a machine", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold)).foregroundStyle(Tone.warning.text)
                Text("The engine runs these, but container no longer lists them as machines, so they can't be opened. They use memory until deleted.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(leftovers) { container in
                    HStack(spacing: DS.Spacing.s) {
                        StatusDot(tone: container.state.isRunning ? .positive : .neutral)
                        Text(container.id).font(DS.Font.mono)
                        Spacer(minLength: DS.Spacing.m)
                        Button("Delete", role: .destructive) { deleteLeftover = container }
                    }
                }
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(Tone.warning.fill.opacity(0.08)))
            .accessibilityIdentifier("machines.leftovers")
        }
    }

    @ViewBuilder
    private func content(_ model: MachinesModel) -> some View {
        if model.loaded && model.machines.isEmpty && !leftovers(model).isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    leftoverPanel(model)
                    Button("New Machine…") { showCreate = true }.buttonStyle(.borderedProminent)
                }
                .padding(DS.Spacing.l)
            }
        } else if model.loaded && model.machines.isEmpty {
            ContentUnavailableView {
                Label("No Machines", systemImage: "desktopcomputer")
            } description: {
                Text("A machine is a Linux VM with your account and your home folder, for working in a shell: install tools, build, run things by hand. Containers are still the way to run services.")
            } actions: {
                Button("New Machine…") { showCreate = true }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    if let machine = model.machines.first(where: { $0.id == selection }) {
                        MachineHero(machine: machine, model: model) { selection = $0 }
                            .id(machine.id)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: DS.Spacing.m, alignment: .top)],
                              spacing: DS.Spacing.m) {
                        ForEach(model.listed.filter { $0.id != selection }) { machine in
                            MachineCard(machine: machine, busy: model.busy.contains(machine.id),
                                        activity: model.renaming[machine.id] != nil ? model.progress : nil) {
                                Task { await model.start(machine.id) }
                            }
                            .cardAction(cornerRadius: DS.Radius.panel) { withAnimation(.snappy) { selection = machine.id } }
                        }
                        Button { showCreate = true } label: {
                            VStack(spacing: DS.Spacing.xs) {
                                Label("New Machine…", systemImage: "plus").font(.callout.weight(.semibold))
                                Text(verbatim: "Ubuntu, Debian, Fedora, Alpine").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.panel - 2)
                                .strokeBorder(DS.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel - 2))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accent)
                    }
                    .accessibilityIdentifier("machines.list")
                    leftoverPanel(model)
                    LearnNote("**Machine or container?** A machine is a full Linux system that boots like a computer and keeps everything you install. Machines reach each other and your containers by name — try `ping \(model.machines.first?.id ?? "name").machine`.")
                }
                .padding(DS.Spacing.l)
            }
            .background(DS.canvas)
        }
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Tone.critical.text)
                .font(.callout)
                .padding(DS.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }
}

extension Machine {
    /// "Ubuntu 24.04" from irekobox-machine-ubuntu:24.04 or ubuntu:24.04.
    var distribution: String {
        var name = imageShortName ?? image?.reference ?? ""
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        name = name.replacingOccurrences(of: "irekobox-machine-", with: "")
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return "Linux" }
        let title = first.prefix(1).uppercased() + first.dropFirst()
        return parts.count > 1 && parts[1] != "latest" ? "\(title) \(parts[1])" : title
    }

    var started: Date? { startedDate.flatMap { try? Date($0, strategy: .iso8601) } }
}

/// Another machine, small: state, what it is, and Start.
private struct MachineCard: View {
    let machine: Machine
    let busy: Bool
    var activity: String?
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                StatusDot(tone: machine.isRunning ? .positive : activity != nil ? .warning : .inactive)
                Text(machine.id).font(.headline)
                if machine.default == true {
                    Text("default").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                Text(machine.isRunning ? "running" : "stopped").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(machine.distribution) · \(machine.cpus) CPUs · \(Format.memory(machine.memory))")
                .font(.callout).foregroundStyle(.secondary)
            if let activity {
                Text(activity).font(.caption).foregroundStyle(Tone.info.text).lineLimit(2)
            } else if !machine.isRunning {
                Button("Start", action: start).buttonStyle(.link).font(.callout).disabled(busy)
            } else if let address = machine.ipAddress {
                Text(address).font(DS.Font.monoSmall).foregroundStyle(.secondary)
            }
        }
        .panel(padding: DS.Spacing.m + DS.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(machine.isRunning ? String(localized: "\(machine.id), running") : String(localized: "\(machine.id), stopped"))
    }
}

/// The selected machine: what it is, how it's doing, how to reach it, and
/// a shell beside it while it runs.
private struct MachineHero: View {
    let machine: Machine
    let model: MachinesModel
    let onRenamed: (String) -> Void
    @Environment(AppState.self) private var app
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var showSettings = false
    @State private var showLog = false
    @State private var stats = LiveStats()

    private var busy: Bool { model.busy.contains(machine.id) }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                header
                reach
                usage
                Spacer(minLength: 0)
                actions
            }
            .frame(minWidth: 300, maxWidth: 380, alignment: .leading)
            shell
                .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 260)
        }
        .panel()
        .task(id: "\(machine.containerId ?? "") \(machine.isRunning)") {
            guard let id = machine.containerId, machine.isRunning else { return }
            await stats.run(engine: app.engine) { [id] in [id] }
        }
        .sheet(isPresented: $renaming) {
            RenameMachineSheet(machine: machine, model: model, onRenamed: onRenamed)
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                MachineOverview(machine: machine, model: model)
                Divider()
                HStack { Spacer(); Button("Done") { showSettings = false }.keyboardShortcut(.defaultAction) }.padding()
            }
            .frame(width: 560, height: 520)
        }
        .sheet(isPresented: $showLog) {
            VStack(spacing: 0) {
                MachineLog(machine: machine, model: model)
                HStack { Spacer(); Button("Done") { showLog = false }.keyboardShortcut(.defaultAction) }.padding()
            }
            .frame(width: 680, height: 520)
        }
        .confirmationDialog("Delete machine “\(machine.id)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(machine.id) } }
        } message: {
            Text("Its disk and everything installed in it is removed. Your home folder on the Mac is not touched.")
        }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: "apple.terminal")
                .font(.title2)
                .foregroundStyle(Color(red: 0.49, green: 0.88, blue: 0.54))
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.12, blue: 0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Text(machine.id).font(.title.weight(.bold))
                    StatusPill(tone: machine.isRunning ? .positive : .neutral, label: machine.isRunning ? "Running" : "Stopped")
                }
                Text(specs).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// "Ubuntu 24.04 · 5 CPUs · 16 GB · up 5h"
    private var specs: String {
        var parts = [machine.distribution, String(localized: "\(machine.cpus) CPUs"), Format.memory(machine.memory)]
        if machine.isRunning, let started = machine.started {
            parts.append(String(localized: "up \(Format.duration(Date().timeIntervalSince(started)))"))
        }
        if machine.default == true { parts.append(String(localized: "default", comment: "Machine: the one `container machine run` uses")) }
        return parts.joined(separator: " · ")
    }

    private var reach: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            FlowRow(spacing: DS.Spacing.xs) {
                pill("\(machine.id).machine", help: "Other machines and containers reach it by this name")
                if let address = machine.ipAddress, machine.isRunning {
                    pill(address, copy: address, help: "Copy the address")
                }
            }
            if let home = machine.userSetup?.home {
                let mode = machine.homeMount ?? "rw"
                Group {
                    if mode == "none" {
                        Text("Your home folder isn't shared")
                    } else if mode == "ro" {
                        Text("Your home folder is shared at `\(home)`, read only")
                    } else {
                        Text("Your home folder is shared at `\(home)`")
                    }
                }
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func pill(_ text: String, copy: String? = nil, help: LocalizedStringKey) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy ?? text, forType: .string)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: text).font(DS.Font.monoSmall)
                Image(systemName: "doc.on.doc").font(.caption2)
            }
            .padding(.horizontal, DS.Spacing.s).padding(.vertical, 3)
            .background(Capsule().fill(DS.accent.opacity(0.1)))
            .foregroundStyle(DS.accent)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var usage: some View {
        let series = machine.containerId.flatMap { stats.series[$0] }
        return HStack(spacing: DS.Spacing.s) {
            tile("CPU", series?.latestCPU.map { "\(Int($0.rounded()))%" } ?? "—")
            tile("Memory", series.map { Format.memory($0.memoryUsage) } ?? "—")
            tile("Disk", machine.diskSize.map { Format.bytes($0) } ?? "—")
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.s + 2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2).fill(DS.subtleFill))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                OpenTerminalWindowButton(target: TerminalTarget(
                    title: machine.id, command: "container machine run -n \(machine.id)",
                    arguments: MachineRepository.shellArguments(machine.id)))
                    .labelStyle(.titleOnly)
                Button("Copy Shell Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("container machine run -n \(machine.id)", forType: .string)
                }
                .help("container machine run -n \(machine.id), for Terminal")
            }
            HStack(spacing: DS.Spacing.s) {
                Button("Rename…") { renaming = true }.disabled(busy)
                if machine.isRunning {
                    Button("Stop") { Task { await model.stop(machine.id) } }.disabled(busy)
                } else {
                    Button("Start") { Task { await model.start(machine.id) } }
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                Menu {
                    Button("Settings…") { showSettings = true }
                    Button("Show Log") { showLog = true }
                    if machine.default != true {
                        Button("Make Default") { Task { await model.makeDefault(machine.id) } }
                    }
                    Divider()
                    Button("Delete Machine", role: .destructive) { confirmDelete = true }.disabled(busy)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More actions for \(machine.id)")
            }
        }
        .buttonStyle(.automatic)
    }

    @ViewBuilder
    private var shell: some View {
        if machine.isRunning {
            MachineTerminal(machine: machine, model: model, binaryPath: app.cli.binaryPath, embedded: true)
                .padding(DS.Spacing.m)
                .background(Color(red: 0.11, green: 0.12, blue: 0.14))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        } else {
            VStack(spacing: DS.Spacing.s) {
                Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary)
                Text("A shell opens here while it runs").foregroundStyle(.secondary)
                Button("Start \(machine.id)") { Task { await model.start(machine.id) } }.disabled(busy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.subtleFill))
        }
    }
}

private struct MachineOverview: View {
    let machine: Machine
    let model: MachinesModel
    @State private var cpus = 0
    @State private var memory = ""
    @State private var homeMount = "rw"

    static let memorySizes = ["2G", "4G", "8G", "16G", "32G"]

    private var changes: [Machine.Setting] {
        var result: [Machine.Setting] = []
        if cpus != machine.cpus { result.append(.cpus(cpus)) }
        if memory != Self.size(machine.memory) { result.append(.memory(memory)) }
        if homeMount != (machine.homeMount ?? "rw") { result.append(.homeMount(homeMount)) }
        return result
    }

    static func size(_ bytes: Int64) -> String { "\(bytes >> 30)G" }

    var body: some View {
        Form {
            Section {
                LabeledContent("Image", value: machine.image?.reference ?? "—")
                if let user = machine.userSetup {
                    LabeledContent("Account", value: String(localized: "\(user.username ?? "?") (uid \(String(user.uid ?? 0))), home \(user.home ?? "?")"))
                }
                if let address = machine.ipAddress, machine.isRunning {
                    LabeledContent("Address") {
                        HStack(spacing: DS.Spacing.s) {
                            Text(address).font(DS.Font.mono).textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy the address")
                                .accessibilityLabel("Copy address")
                        }
                    }
                    LabeledContent("Name for others") {
                        Text(verbatim: "\(machine.id) · \(machine.id).machine").font(DS.Font.mono).textSelection(.enabled)
                            .help("Other machines, and this one, reach it by these names (kept in their /etc/hosts)")
                    }
                }
                if let disk = machine.diskSize {
                    LabeledContent("Disk used", value: ByteCountFormatter.string(fromByteCount: disk, countStyle: .file))
                }
                LabeledContent("Default") {
                    if machine.default == true {
                        Text("Yes — `container machine run` uses it").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { Task { await model.makeDefault(machine.id) } }
                    }
                }
            }
            Section {
                Stepper("CPUs: \(cpus)", value: $cpus, in: 1...max(ProcessInfo.processInfo.activeProcessorCount, cpus))
                Picker("Memory", selection: $memory) {
                    ForEach(Array(Set(Self.memorySizes + [Self.size(machine.memory)])).sorted { Int($0.dropLast())! < Int($1.dropLast())! },
                            id: \.self) { Text($0).tag($0) }
                }
                Picker("Your home folder", selection: $homeMount) {
                    Text("Read and write").tag("rw")
                    Text("Read only").tag("ro")
                    Text("Not shared").tag("none")
                }
            } header: {
                Text("Settings")
            } footer: {
                HStack {
                    Text(machine.isRunning ? "Changes apply after a restart." : "Changes apply at the next start.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(machine.isRunning ? "Apply and Restart" : "Apply") {
                        Task { await model.apply(machine.id, changes, restart: machine.isRunning) }
                    }
                    .disabled(changes.isEmpty || model.busy.contains(machine.id))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cpus = machine.cpus
            memory = Self.size(machine.memory)
            homeMount = machine.homeMount ?? "rw"
        }
    }
}

private struct MachineTerminal: View {
    let machine: Machine
    let model: MachinesModel
    let binaryPath: String
    /// In the machine card: dark, no header (the card has the actions).
    var embedded = false
    @State private var sessionID = UUID()
    @State private var ended: Int32??

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { header }
            session
        }
    }

    private var header: some View {
            HStack {
                Text(verbatim: "container machine run -n \(machine.id)")
                    .font(DS.Font.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                OpenTerminalWindowButton(target: TerminalTarget(
                    title: machine.id, command: "container machine run -n \(machine.id)",
                    arguments: MachineRepository.shellArguments(machine.id)))
                    .controlSize(.small)
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.bottom, DS.Spacing.xs)
    }

    private var session: some View {
        Group {
            if let code = ended {
                ContentUnavailableView {
                    Label("Session ended", systemImage: "terminal")
                } description: {
                    Text(code.map { String(localized: "The shell exited with code \(String($0)).") } ?? String(localized: "The shell ended."))
                } actions: {
                    Button("New Session") { ended = nil; sessionID = UUID() }
                }
            } else {
                ContainerTerminalView(binaryPath: binaryPath, arguments: MachineRepository.shellArguments(machine.id),
                                      dark: embedded) { code in
                    Task { @MainActor in ended = .some(code) }
                }
                .id(sessionID)
            }
        }
        .overlay(alignment: .top) {
            if !machine.isRunning && ended == nil {
                Text("Starting the machine…").font(.caption).padding(DS.Spacing.xs).background(.bar, in: Capsule())
                    .padding(DS.Spacing.s)
            }
        }
    }
}

private struct MachineLog: View {
    let machine: Machine
    let model: MachinesModel
    @State private var boot = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                Picker("Log", selection: $boot) {
                    Text("Machine").tag(false)
                    Text("Boot").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button { Task { text = await model.logs(machine.id, boot: boot) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                    .accessibilityLabel("Reload log")
            }
            ScrollView {
                Text(text.isEmpty ? String(localized: "Nothing logged.") : text)
                    .font(DS.Font.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.s)
            }
            .defaultScrollAnchor(.bottomLeading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.subtleFill))
        }
        .padding(DS.Spacing.s)
        .task(id: boot) { text = await model.logs(machine.id, boot: boot) }
    }
}

/// Rename a machine: a new one with the old one's disk, then the old one goes.
private struct RenameMachineSheet: View {
    let machine: Machine
    let model: MachinesModel
    let onRenamed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renaming = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    /// Another machine has it (not this one, not the one this rename makes).
    private var taken: Bool {
        !renaming && trimmed != machine.id && model.machines.contains { $0.id == trimmed }
    }
    private var unchanged: Bool { trimmed == machine.id }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Rename “\(machine.id)”").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("New name").font(.callout.weight(.medium))
                TextField("New name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(rename)
                Group {
                    if !renaming && !trimmed.isEmpty && (!MachineRepository.isValidName(trimmed) || taken) {
                        Text(taken ? "A machine with this name exists." : "Use lowercase letters, digits and hyphens; start and end with a letter or digit.")
                            .foregroundStyle(Tone.warning.text)
                    } else if !unchanged && !trimmed.isEmpty {
                        Label("available · \(machine.id) keeps all its files", systemImage: "checkmark")
                            .foregroundStyle(Tone.positive.text)
                    }
                }
                .font(.caption)
            }
            Text(machine.isRunning
                 ? "The machine restarts once. Open terminals reconnect. Its address may change."
                 : "Everything installed stays. Its address may change.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("container can't rename machines: Irekobox makes a new one with this machine's disk (the copy takes no extra space) and then removes the old name.")
            if renaming, let progress = model.progress {
                HStack(spacing: DS.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.automatic).keyboardShortcut(.cancelAction).disabled(renaming)
                Button(renaming ? "Renaming…" : "Rename", action: rename)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renaming || taken || unchanged || !MachineRepository.isValidName(trimmed))
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440)
        .onAppear { name = machine.id }
    }

    private func rename() {
        guard !renaming, !unchanged, MachineRepository.isValidName(trimmed), !taken else { return }
        Task {
            renaming = true
            let ok = await model.rename(machine.id, to: trimmed)
            renaming = false
            if ok {
                onRenamed(trimmed)
                dismiss()
            }
        }
    }
}

/// Create a machine from an image.
struct NewMachineSheet: View {
    let model: MachinesModel
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image = "ubuntu:24.04"
    @State private var name = ""
    @State private var creating = false
    /// Whether this creation builds the systemd image first.
    @State private var preparing = false
    @State private var suggester: ImageSuggester = {
        let suggester = ImageSuggester(only: MachineImage.distributions.map {
            SearchResult(name: $0.name, description: $0.about, star_count: 0, is_official: true, is_automated: false)
        })
        suggester.minimumLength = 1
        return suggester
    }()

    private var typedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// What it's called when the field stays empty.
    private var suggestedName: String {
        MachineRepository.suggestedName(for: image.trimmingCharacters(in: .whitespaces),
                                        taken: Set(model.machines.map(\.id)).union(model.heldNames))
    }

    private var imageNote: String? {
        let image = self.image.trimmingCharacters(in: .whitespaces)
        if MachineImage.needsPreparing(image) {
            let prepared = MachineImage.preparedTag(for: image)
            if model.preparedImages.contains(prepared) { return nil }
            return String(localized: "The first \(image) machine takes about a minute longer: Irekobox adds systemd to the image, which a machine needs to boot.")
        }
        if MachineImage.family(of: image) == .unknown, !image.isEmpty {
            return String(localized: "The image needs an init system (/sbin/init) to run as a machine; most container images have none.")
        }
        return nil
    }

    /// The four on the cards: what, which release.
    static let cards: [(name: String, version: String, image: String)] = [
        ("Ubuntu", "24.04 LTS", "ubuntu:24.04"), ("Debian", "12", "debian:12"),
        ("Fedora", "41", "fedora:41"),
        ("Alpine", String(localized: "latest", comment: "Machine card: the newest release of a distribution"), "alpine:latest"),
    ]
    @State private var anotherImage = false

    private var nameTaken: Bool {
        let chosen = typedName.isEmpty ? suggestedName : typedName
        return model.machines.contains { $0.id == chosen } || model.heldNames.contains(chosen)
    }

    private var resources: String {
        let memory = Format.memory(Int64(ProcessInfo.processInfo.physicalMemory / 2))
        return String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) CPUs · \(memory) memory · your home folder · change any of it later")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("New Machine").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                HStack(spacing: DS.Spacing.s) {
                    ForEach(Self.cards, id: \.image) { card in
                        let chosen = image == card.image && !anotherImage
                        Button {
                            anotherImage = false
                            image = card.image
                        } label: {
                            VStack(spacing: 4) {
                                Text(card.name).font(.headline)
                                Text(card.version).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.raised))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                                .strokeBorder(chosen ? DS.accent : Color.primary.opacity(0.08), lineWidth: chosen ? 2 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                if anotherImage {
                    TextField("Image", text: $image, prompt: Text("e.g. rockylinux:9"))
                        .textFieldStyle(.roundedBorder)
                        .imageSuggestions(suggester)
                        .onChange(of: image) { _, value in suggester.suggest(value) }
                } else {
                    Button("Another image…") {
                        anotherImage = true
                        image = ""
                    }
                    .buttonStyle(.link).font(.callout)
                }
                HStack(spacing: DS.Spacing.s) {
                    Text("Name")
                    TextField("Name", text: $name, prompt: Text(suggestedName))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .labelsHidden()
                    if !typedName.isEmpty && !MachineRepository.isValidName(typedName) {
                        Text("lowercase letters, digits, hyphens").font(.caption).foregroundStyle(Tone.warning.text)
                    } else if model.heldNames.contains(typedName) {
                        Text("held by a deleted machine").font(.caption).foregroundStyle(Tone.warning.text)
                    } else if nameTaken {
                        Text("taken").font(.caption).foregroundStyle(Tone.warning.text)
                    } else {
                        Label("available", systemImage: "checkmark").font(.caption).foregroundStyle(Tone.positive.text)
                    }
                }
            }
            .disabled(creating)
            Text(resources)
                .font(.callout).foregroundStyle(.secondary)
            if creating {
                CreationProgress(prepares: preparing, image: image.trimmingCharacters(in: .whitespaces),
                                 step: model.creation, buildLine: model.buildLine)
            } else if let imageNote {
                Text(imageNote)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.accent.opacity(0.08)))
            }
            if let held = model.heldName, !creating {
                // Not a failure to fix elsewhere: another name works now.
                Label("\(held) is still held by a deleted machine until the engine restarts, so this one is called \(suggestedName). Create it again, or type another name.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = model.error, !creating {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.automatic)
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create Machine") {
                    Task {
                        let image = image.trimmingCharacters(in: .whitespaces)
                        preparing = MachineImage.needsPreparing(image)
                            && !model.preparedImages.contains(MachineImage.preparedTag(for: image))
                        creating = true
                        let chosen = typedName.isEmpty ? suggestedName : typedName
                        let ok = await model.create(image: image.trimmingCharacters(in: .whitespaces), name: chosen)
                        creating = false
                        // The held name gives way to the next free one.
                        if model.heldName == chosen { name = "" }
                        if ok {
                            onCreated(chosen)
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(creating || nameTaken || image.trimmingCharacters(in: .whitespaces).isEmpty || image.hasSuffix(":")
                          || !MachineRepository.isValidName(typedName.isEmpty ? suggestedName : typedName))
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 500)
    }
}

/// What creating a machine is doing: its steps, ticked off, and the image
/// build's last line. One height throughout, so the sheet stays still.
private struct CreationProgress: View {
    let prepares: Bool
    let image: String
    let step: MachinesModel.CreationStep?
    let buildLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if prepares {
                row(String(localized: "Prepare \(image): add systemd (once, about a minute)"),
                    done: step == .starting, current: step == .preparing || step == nil)
            }
            row(String(localized: "Create the machine and boot it"), done: false, current: step == .starting)
            // Always there, so a build line coming or going doesn't move anything.
            Text(prepares && step != .starting ? buildLine ?? " " : " ")
                .font(DS.Font.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 22)
                .accessibilityHidden(buildLine == nil)
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.accent.opacity(0.08)))
    }

    private func row(_ title: String, done: Bool, current: Bool) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.positive.text)
                } else if current {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 14, height: 14)
            Text(title)
                .font(.callout)
                .foregroundStyle(done || current ? .primary : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? String(localized: "done") : current ? String(localized: "in progress") : "")
    }
}
