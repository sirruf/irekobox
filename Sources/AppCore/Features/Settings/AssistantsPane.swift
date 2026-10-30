import SwiftUI
import MCPKit

/// Settings › AI Assistants: the apps that can see and manage containers
/// through the MCP server, each with its own key and access level.
struct AssistantsPane: View {
    @State private var settings = AssistantFiles.load()
    @State private var activity: [AssistantActivity] = []
    @State private var error: String?
    @State private var adding = false
    @State private var showLog = false
    @State private var refresh = 0

    /// The server the clients run, inside this app.
    static var serverPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/IrekoboxMCP").path
    }

    var body: some View {
        Form {
            Section {
                ForEach(AssistantClient.all.filter { $0.isInstalled() || $0.connectedKey() != nil }) { client in
                    clientRow(client)
                }
                ForEach(settings.assistants.filter { $0.client == "custom" }) { assistant in
                    customRow(assistant)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assistants on this Mac").font(.headline)
                    Text("Any app that speaks MCP can see and manage your containers. Each one gets its own access. Nothing leaves this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack(alignment: .top, spacing: DS.Spacing.l) {
                    ForEach(AccessLevel.allCases, id: \.self) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.displayTitle).font(.callout.weight(.semibold))
                            Text(level.displaySummary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Picker(selection: binding(\.newAssistantLevel)) {
                    ForEach(AccessLevel.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                } label: {
                    Text("New assistants start with")
                    Text("Also for an assistant set up by hand without a key.")
                }
                Toggle(isOn: binding(\.askBeforeDeleting)) {
                    Text("Ask me before deleting anything")
                    Text("Shows a notification you approve, whichever assistant asks.")
                }
            }
            Section {
                HStack {
                    Text("Another assistant? Add it with its own key:").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Assistant…") { adding = true }.buttonStyle(.automatic)
                    Button("Activity Log") { showLog = true }.buttonStyle(.automatic)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
                }
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .task { await watch() }
        .sheet(isPresented: $adding) {
            AddAssistantSheet(level: settings.newAssistantLevel) { assistant in
                settings.assistants.append(assistant)
                save()
            }
        }
        .sheet(isPresented: $showLog) { ActivityLogSheet(entries: activity) }
    }

    // MARK: - Rows

    private func clientRow(_ client: AssistantClient) -> some View {
        let connection = client.connection()
        let assistant = settings.assistant(forKey: connection?.key)
        let stale = connection != nil && connection?.command != nil && connection?.command != Self.serverPath
        return HStack(spacing: DS.Spacing.m) {
            StatusDot(tone: assistant != nil && !stale ? .positive : .inactive)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Text(client.name).font(.callout.weight(.semibold))
                    Text(assistant == nil ? "Found" : stale ? "Moved — reconnect" : "Connected")
                        .font(.caption)
                        .foregroundStyle(assistant == nil ? .secondary : stale ? Tone.warning.text : Tone.positive.text)
                }
                Text(assistant.map(lastAction) ?? String(localized: "Not connected")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let assistant, !stale {
                Picker("Access", selection: levelBinding(assistant)) {
                    ForEach(AccessLevel.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("Disconnect") { disconnect(client, assistant) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More for \(client.name)")
            } else {
                Button(stale ? "Reconnect" : "Connect…") { connect(client, replacing: assistant) }
                    .buttonStyle(.borderedProminent)
                    .help("Adds Irekobox to \(client.name)'s MCP servers with its own key")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func customRow(_ assistant: Assistant) -> some View {
        HStack(spacing: DS.Spacing.m) {
            StatusDot(tone: .positive)
            VStack(alignment: .leading, spacing: 2) {
                Text(assistant.name).font(.callout.weight(.semibold))
                Text(lastAction(assistant)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Access", selection: levelBinding(assistant)) {
                ForEach(AccessLevel.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("Copy Config") { copySnippet(assistant.key) }
                Button("Remove", role: .destructive) {
                    settings.assistants.removeAll { $0.id == assistant.id }
                    save()
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More for \(assistant.name)")
        }
    }

    /// "Last action 4 min ago: restarted shop-api-1", or "Never used yet".
    private func lastAction(_ assistant: Assistant) -> String {
        guard let last = activity.first(where: { $0.assistant == assistant.name }) else { return String(localized: "Never used yet") }
        let when = last.date.formatted(.relative(presentation: .named))
        return last.outcome == .done ? String(localized: "Last action \(when): \(last.summary)")
            : String(localized: "Last action \(when): \(last.summary) (\(last.outcome.displayTitle))")
    }

    // MARK: - Changes

    private func binding<Value>(_ keyPath: WritableKeyPath<AssistantSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0; save() })
    }

    private func levelBinding(_ assistant: Assistant) -> Binding<AccessLevel> {
        Binding(get: { settings.assistants.first { $0.id == assistant.id }?.level ?? assistant.level },
                set: { level in
                    if let index = settings.assistants.firstIndex(where: { $0.id == assistant.id }) {
                        settings.assistants[index].level = level
                        save()
                    }
                })
    }

    private func save() {
        do {
            try AssistantFiles.save(settings)
            error = nil
        } catch {
            self.error = String(localized: "Couldn't save: \(error.localizedDescription)")
        }
    }

    private func connect(_ client: AssistantClient, replacing old: Assistant?) {
        let assistant = old ?? Assistant(name: client.name, client: client.id, level: settings.newAssistantLevel)
        do {
            try ClientConnector.connect(client, command: Self.serverPath, key: assistant.key)
            if old == nil { settings.assistants.append(assistant) }
            save()
            refresh += 1
        } catch {
            self.error = String(localized: "Couldn't connect \(client.name): \(error.localizedDescription)")
        }
    }

    private func disconnect(_ client: AssistantClient, _ assistant: Assistant) {
        do {
            try ClientConnector.disconnect(client)
            settings.assistants.removeAll { $0.id == assistant.id }
            save()
            refresh += 1
        } catch {
            self.error = String(localized: "Couldn't disconnect \(client.name): \(error.localizedDescription)")
        }
    }

    private func copySnippet(_ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AssistantClient.snippet(command: Self.serverPath, key: key), forType: .string)
    }

    /// Re-read the activity (assistants act while Settings is open).
    private func watch() async {
        while !Task.isCancelled {
            activity = ActivityLog.read()
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Writes a client's config: one vendor's coding assistant through its own
/// `mcp add` command when it's installed (its config file is busy and large),
/// the others by editing their file.
enum ClientConnector {
    static var vendorCLI: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let name = AssistantClient.vendor
        return ["\(home)/.local/bin/\(name)", "\(home)/.\(name)/local/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func connect(_ client: AssistantClient, command: String, key: String) throws {
        if client.id == AssistantClient.codeClientID, let cli = vendorCLI {
            _ = try? run(cli, ["mcp", "remove", "--scope", "user", AssistantClient.serverName])
            try run(cli, ["mcp", "add", "--scope", "user", AssistantClient.serverName,
                             "--env", "\(AssistantClient.keyVariable)=\(key)", "--", command])
        } else {
            try client.connect(command: command, key: key)
        }
    }

    static func disconnect(_ client: AssistantClient) throws {
        if client.id == AssistantClient.codeClientID, let cli = vendorCLI {
            try run(cli, ["mcp", "remove", "--scope", "user", AssistantClient.serverName])
        } else {
            try client.disconnect()
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ToolError(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}

/// A key for an assistant set up by hand: its name, then the config to paste.
private struct AddAssistantSheet: View {
    let level: AccessLevel
    let add: (Assistant) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var created: Assistant?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Add Assistant").font(.title2.weight(.semibold))
            if let created {
                Text("Add this to \(created.name)'s MCP servers. It starts with \(created.level.displayTitle); change it in the list.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(AssistantClient.snippet(command: AssistantsPane.serverPath, key: created.key))
                        .font(DS.Font.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.m)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.subtleFill))
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AssistantClient.snippet(command: AssistantsPane.serverPath, key: created.key),
                                                       forType: .string)
                    }
                    .buttonStyle(.automatic)
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                Text("For an app not listed: give it a name, then paste its config into that app.")
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name, prompt: Text("e.g. Zed"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.automatic).keyboardShortcut(.cancelAction)
                    Button("Create Key") {
                        let assistant = Assistant(name: name.trimmingCharacters(in: .whitespaces), client: "custom", level: level)
                        add(assistant)
                        created = assistant
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 520)
    }
}

/// What assistants did, newest first.
private struct ActivityLogSheet: View {
    let entries: [AssistantActivity]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Activity Log").font(.title2.weight(.semibold))
            if entries.isEmpty {
                ContentUnavailableView("Nothing Yet", systemImage: "text.badge.checkmark",
                                       description: Text("What assistants look at and change shows up here."))
            } else {
                Table(entries) {
                    TableColumn("When") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 120, ideal: 140)
                    TableColumn("Assistant", value: \.assistant).width(min: 90, ideal: 120)
                    TableColumn("What", value: \.summary)
                    TableColumn("") { entry in
                        Text(entry.outcome.displayTitle)
                            .foregroundStyle(entry.outcome == .done ? Color.secondary : Tone.warning.text)
                    }
                    .width(70)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 680, height: 460)
    }
}

/// The access levels and outcomes in the user's language (MCPKit's own
/// titles are English, for the server).
extension AccessLevel {
    var displayTitle: String {
        switch self {
        case .lookOnly: String(localized: "Look only")
        case .operate: String(localized: "Look and operate")
        case .everything: String(localized: "Everything")
        }
    }

    var displaySummary: String {
        switch self {
        case .lookOnly: String(localized: "See containers, logs, stats, clusters.")
        case .operate: String(localized: "Also start, stop, restart, scale, pull. No deleting.")
        case .everything: String(localized: "Also create, delete, apply YAML, run commands inside.")
        }
    }
}

extension AssistantActivity.Outcome {
    var displayTitle: String {
        switch self {
        case .done: String(localized: "done", comment: "An assistant's action: completed")
        case .failed: String(localized: "failed", comment: "An assistant's action: went wrong")
        case .refused: String(localized: "refused", comment: "An assistant's action: not allowed by its access level")
        case .declined: String(localized: "declined", comment: "An assistant's action: the user said no")
        }
    }
}
