import SwiftUI
import UniformTypeIdentifiers
import ContainerKit
import MigrationKit

/// Run a container (⌘N): an image and its settings, or a pasted `docker run`.
/// Shows the exact `container run` command and checks ports, names and paths
/// before anything starts.
struct RunSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: RunSheetModel
    @State private var suggester = ImageSuggester()
    @FocusState private var imageFocused: Bool
    /// Called with the new container's name (when known) after it started.
    var onStarted: (String?) -> Void = { _ in }

    init(image: String = "", onStarted: @escaping (String?) -> Void = { _ in }) {
        _model = State(initialValue: RunSheetModel(image: image))
        self.onStarted = onStarted
    }

    init(configuration: RunConfiguration, paste: Bool, onStarted: @escaping (String?) -> Void = { _ in }) {
        let model = RunSheetModel()
        model.config = configuration
        model.mode = paste ? .paste : .form
        _model = State(initialValue: model)
        self.onStarted = onStarted
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    // The image field offers "or paste docker run …"; the paste view leads back.
                    if model.mode == .paste {
                        Button { model.mode = .form } label: {
                            Label("Pick an image instead", systemImage: "chevron.backward")
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("run.mode")
                    }
                    switch model.mode {
                    case .form: form
                    case .paste: paste
                    }
                    if let error = model.runError {
                        NoticeBanner(tone: .critical, title: "Couldn't start the container", message: error)
                    }
                }
                .padding(.horizontal, DS.Spacing.xl + 2)
                .padding(.vertical, DS.Spacing.xl)
            }
            .frame(maxWidth: .infinity)
            .background(DS.dynamic(light: 0xFBFBFD, dark: 0x1E1E20))
            Divider()
            aside.frame(width: 330)
        }
        .frame(width: 960, height: 660)
        // Esc cancels even from the image field, which would otherwise take it
        // for completion.
        .onExitCommand { dismiss() }
        .onAppear {
            model.existingNames = Set(app.model.containers.map(\.id))
            model.usedHostPorts = Set(app.model.containers.filter { $0.state.isRunning }
                .flatMap { $0.configuration.publishedPorts ?? [] }.map(\.hostPort))
        }
        .task { await app.model.observe([.images, .networks, .volumes]) }
        .task(id: model.config.image) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await model.loadHints(for: model.config.image, engine: app.engine,
                                  local: app.model.images.map(\.reference))
        }
        // `.contain` keeps the ids of the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run.sheet")
    }

    // MARK: - Aside: the command and the buttons

    private var aside: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Same thing as a command").font(.callout.weight(.semibold))
            let command = model.commandLine
            ScrollView {
                Text(command.isEmpty ? "container run …" : command)
                    .font(DS.Font.monoSmall)
                    .foregroundStyle(Color(white: 0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.m)
                    .accessibilityIdentifier("run.command")
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.114, green: 0.122, blue: 0.137)))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
            }
            .disabled(command.isEmpty)
            Text("Change anything on the left and the command updates — a good way to learn the CLI.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Spacing.m)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.accent.opacity(0.06)))
                .hairline(RoundedRectangle(cornerRadius: DS.Radius.card), DS.accent.opacity(0.25))
            Spacer(minLength: 0)
            if model.isRunning {
                HStack(spacing: DS.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Starting… the image is pulled first if it isn't on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Spacing.s) {
                Button { dismiss() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        if await model.run(engine: app.engine) {
                            await app.model.refresh([.containers])
                            onStarted(model.containerName)
                            dismiss()
                        }
                    }
                } label: { Text("Run").frame(maxWidth: .infinity) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
                .accessibilityIdentifier("run.submit")
            }
            .controlSize(.large)
        }
        .padding(DS.Spacing.xl - 2)
        .frame(maxHeight: .infinity)
        .background(DS.dynamic(light: 0xEEF0F4, dark: 0x252528))
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s + 2) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Image, e.g. nginx:alpine", text: $model.config.image)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($imageFocused)
                        .accessibilityIdentifier("run.image")
                        .imageSuggestions(suggester)
                        .onChange(of: model.config.image) { _, value in
                            suggester.suggest(value, local: app.model.images.filter { !$0.isSystem }.map(\.reference))
                        }
                    Button("or paste docker run …") { model.mode = .paste }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, DS.Spacing.m + 2)
                .padding(.vertical, DS.Spacing.s + 2)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.raised))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(imageFocused ? DS.accent : DS.separator, lineWidth: imageFocused ? 2 : 0.5))
                imageNote
                issueRows(.image)
            }
            Grid(alignment: .topLeading, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.m) {
                GridRow {
                    field("Name") {
                        TextField("Optional", text: $model.config.name)
                            .textFieldStyle(.roundedBorder)
                            .font(DS.Font.mono)
                            .accessibilityIdentifier("run.name")
                        issueRows(.name)
                    }
                    field("Open on this Mac", .publishedPort) { ports }
                }
                GridRow {
                    field(model.hints?.required.isEmpty == false ? "Needed by this image" : "Environment",
                          .environment) { variables }
                        .gridCellColumns(2)
                }
                GridRow {
                    field("Keep data", .volume) { mounts }
                        .gridCellColumns(2)
                }
            }
            DisclosureGroup("More options: resources, platform, network, command") { moreOptions }
                .font(.callout)
        }
    }

    /// A white field card with a small caption, as on the design.
    private func field<Content: View>(_ title: LocalizedStringKey, _ term: Glossary? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.xs) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let term { TermInfo(term) }
            }
            content()
        }
        .padding(.horizontal, DS.Spacing.m + 2)
        .padding(.vertical, DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel - 2).fill(DS.raised)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1))
        .hairline(RoundedRectangle(cornerRadius: DS.Radius.panel - 2), DS.separator.opacity(0.5))
    }

    private var moreOptions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.m) {
            GridRow {
                label("Resources", .resources)
                HStack(spacing: DS.Spacing.l) {
                    Picker("CPUs", selection: $model.config.cpus) {
                        Text("Default").tag(Int?.none)
                        ForEach([1, 2, 4, 8], id: \.self) { Text(verbatim: String($0)).tag(Int?.some($0)) }
                    }
                    .fixedSize()
                    Picker("Memory", selection: $model.config.memoryMiB) {
                        Text("Default").tag(Int?.none)
                        ForEach([256, 512, 1024, 2048, 4096, 8192], id: \.self) {
                            Text(Format.memory(Int64($0) * 1_048_576)).tag(Int?.some($0))
                        }
                    }
                    .fixedSize()
                }
            }
            GridRow {
                label("Platform", .platform)
                Picker("Platform", selection: $model.config.amd64) {
                    Text("arm64 (native)").tag(false)
                    Text("amd64 via Rosetta").tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }
            GridRow {
                label("Network", .network)
                Picker("Network", selection: $model.config.network) {
                    Text("Default").tag(String?.none)
                    ForEach(app.model.networks.filter { !$0.isBuiltin }) { Text($0.name).tag(String?.some($0.name)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                label("Command")
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    TextField("Image default", text: $model.config.command)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Font.mono)
                    Toggle("Remove the container when it stops", isOn: $model.config.removeWhenStopped)
                }
            }
        }
        .padding(.top, DS.Spacing.s)
    }

    private func label(_ text: LocalizedStringKey, _ term: Glossary? = nil) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(text).foregroundStyle(.secondary)
            if let term { TermInfo(term) }
        }
        .gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private var imageNote: some View {
        let query = model.config.image.trimmingCharacters(in: .whitespaces).lowercased()
        let local = app.model.images.filter { !$0.isSystem }
        if let note = suggester.note {
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if !query.isEmpty && !query.hasSuffix(":")
                    && !local.contains(where: { $0.shortName.lowercased() == query || $0.reference.lowercased() == query }) {
            Text("Not on this Mac yet — it will be pulled when the container starts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ports: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach($model.config.ports) { $port in
                HStack(spacing: DS.Spacing.xs) {
                    TextField("Host", text: $port.host)
                        .frame(width: 72)
                        .accessibilityLabel("Host port")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Container", text: $port.container)
                        .frame(width: 80)
                        .accessibilityLabel("Container port")
                    Picker("Protocol", selection: $port.proto) {
                        ForEach(RunConfiguration.PortProtocol.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    removeButton { [id = port.id] in model.config.ports.removeAll { $0.id == id } }
                }
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.mono)
                issueRows(.port(port.id))
            }
            Button("Add Port") { model.config.ports.append(.init()) }
                .buttonStyle(.link)
                .accessibilityIdentifier("run.addPort")
        }
    }

    private var mounts: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach($model.config.mounts) { $mount in
                HStack(spacing: DS.Spacing.xs) {
                    TextField("~/folder or volume", text: $mount.source)
                    Button("Choose…") { chooseFolder(for: mount.id) }
                        .controlSize(.small)
                        .help("A folder on this Mac")
                    if !app.model.volumes.isEmpty {
                        Menu {
                            ForEach(app.model.volumes.map(\.name).sorted(), id: \.self) { name in
                                Button(name) { mount.source = name }
                            }
                        } label: {
                            Image(systemName: "externaldrive")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("An existing volume")
                        .accessibilityLabel("Existing volumes")
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("/path/in/container", text: $mount.target)
                    Toggle("Read-only", isOn: $mount.readOnly).toggleStyle(.checkbox)
                    removeButton { [id = mount.id] in model.config.mounts.removeAll { $0.id == id } }
                }
                .textFieldStyle(.roundedBorder)
                issueRows(.mount(mount.id))
            }
            Button("Add Volume") { model.config.mounts.append(.init()) }
                .buttonStyle(.link)
        }
    }

    private var variables: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach($model.config.variables) { $variable in
                HStack(spacing: DS.Spacing.xs) {
                    TextField("NAME", text: $variable.key).frame(width: 160)
                    Text(verbatim: "=").foregroundStyle(.secondary)
                    TextField("value", text: $variable.value)
                    removeButton { [id = variable.id] in model.config.variables.removeAll { $0.id == id } }
                }
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.mono)
                issueRows(.variable(variable.id))
            }
            HStack(spacing: DS.Spacing.l) {
                Button("Add Variable") { model.config.variables.append(.init()) }
                Button("Import .env…") { importEnvFile() }
            }
            .buttonStyle(.link)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
    }

    @ViewBuilder
    private func issueRows(_ field: RunConfiguration.Issue.Field) -> some View {
        ForEach(model.issues(for: field)) { issue in
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? Tone.critical.fill : Tone.warning.fill)
                    .accessibilityHidden(true)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(issue.severity == .error ? Tone.critical.text : Tone.warning.text)
                if let suggestion = issue.suggestion, case .hostPort(_, let value) = suggestion {
                    Button("Use \(value)") { model.apply(suggestion) }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Paste

    private var paste: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Paste a `docker run` command; it's translated to `container run`.")
                .foregroundStyle(.secondary)
            TextEditor(text: $model.pasted)
                .font(DS.Font.mono)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(DS.Spacing.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.separator))
                .accessibilityIdentifier("run.paste")
            if let error = model.translationError {
                NoticeBanner(tone: .critical, title: "Can't translate this command", message: error)
            }
            if let warnings = model.translation?.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    SectionHeader("Differences from Docker")
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                            Image(systemName: warning.severity == .unsupported ? "xmark.octagon" : "info.circle")
                                .foregroundStyle(warning.severity == .unsupported ? Tone.critical.fill : Tone.warning.fill)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: "--\(warning.flag)").font(DS.Font.monoSmall)
                                Text(warning.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Panels

    private func chooseFolder(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Choose", comment: "Open panel button: pick a folder")
        guard panel.runModal() == .OK, let url = panel.url,
              let index = model.config.mounts.firstIndex(where: { $0.id == id }) else { return }
        let home = NSHomeDirectory()
        model.config.mounts[index].source = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func importEnvFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Import", comment: "Open panel button: import a .env file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            model.config.variables.append(contentsOf: RunConfiguration.parseEnvFile(text))
        } catch {
            model.runError = String(localized: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
