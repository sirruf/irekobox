import SwiftUI
import ContainerKit

/// Structured editor for a container's networks / ports / volumes / env, with
/// per-field validation, then **recreate** (delete + run).
struct EditContainerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let container: Container
    var onRecreated: () -> Void

    @State private var model: EditContainerModel
    @State private var isWorking = false
    @State private var error: String?

    init(container: Container, onRecreated: @escaping () -> Void) {
        self.container = container
        self.onRecreated = onRecreated
        _model = State(initialValue: EditContainerModel(container: container))
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Edit \(container.id)").font(.title3.weight(.semibold))
                    .accessibilityIdentifier("editSheet.title")
                Text("Changes recreate the container. Volumes and their data stay; files changed inside the container don't.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()

            Form {
                resourcesSection(model)
                networksSection(model)
                portsSection(model)
                volumesSection(model)
                envSection(model)
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 620, height: 620)
    }

    // MARK: - Sections

    /// Memory sizes to offer, plus whatever it has now.
    private func memoryChoices(_ current: Int64) -> [Int64] {
        Array(Set([256, 512, 1024, 2048, 4096, 8192, 16384, current])).sorted()
    }

    private func resourcesSection(_ model: EditContainerModel) -> some View {
        @Bindable var model = model
        return Section("Resources") {
            Stepper(value: $model.cpus, in: 1...max(ProcessInfo.processInfo.activeProcessorCount, model.cpus)) {
                LabeledContent("CPUs", value: "\(model.cpus)")
            }
            .accessibilityIdentifier("editSheet.cpus")
            Picker("Memory", selection: $model.memoryMiB) {
                ForEach(memoryChoices(model.memoryMiB), id: \.self) { mib in
                    Text(Format.memory(mib * 1024 * 1024)).tag(mib)
                }
            }
            .accessibilityIdentifier("editSheet.memory")
        }
    }

    private func networksSection(_ model: EditContainerModel) -> some View {
        Section("Networks") {
            ForEach($model.networks) { $row in
                rowControls(error: model.networkError(row), onRemove: { remove(\.networks, row.id) }) {
                    Picker("Network", selection: $row.name) {
                        if row.name.isEmpty { Text("Choose…").tag("") }
                        ForEach(networkNames(including: row.name), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            addButton("Add Network") { model.networks.append(.init()) }
        }
    }

    private func portsSection(_ model: EditContainerModel) -> some View {
        Section("Ports") {
            ForEach($model.ports) { $row in
                rowControls(error: model.portError(row), onRemove: { remove(\.ports, row.id) }) {
                    TextField("host", text: $row.host).frame(width: 70)
                        .accessibilityIdentifier("editSheet.port.host")
                    Text(verbatim: ":").foregroundStyle(.secondary)
                    TextField("container", text: $row.container).frame(width: 80)
                        .accessibilityIdentifier("editSheet.port.container")
                    Picker("", selection: $row.proto) { Text(verbatim: "tcp").tag("tcp"); Text(verbatim: "udp").tag("udp") }
                        .labelsHidden().frame(width: 70)
                }
            }
            addButton("Add Port") { model.ports.append(.init()) }
                .accessibilityIdentifier("editSheet.port.add")
        }
    }

    private func volumesSection(_ model: EditContainerModel) -> some View {
        Section("Volumes") {
            ForEach($model.volumes) { $row in
                rowControls(error: model.volumeError(row), onRemove: { remove(\.volumes, row.id) }) {
                    TextField("volume or folder", text: $row.source)
                    Menu {
                        ForEach(app.model.volumes.map(\.name).sorted(), id: \.self) { name in
                            Button(name) { row.source = name }
                        }
                        if app.model.volumes.isEmpty { Text("No volumes yet") }
                        Divider()
                        Button("Folder on This Mac…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url { row.source = url.path }
                        }
                    } label: { Image(systemName: "externaldrive") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Pick a volume or a folder")
                    Text(verbatim: ":").foregroundStyle(.secondary)
                    TextField("/destination", text: $row.destination)
                    Toggle("ro", isOn: $row.readOnly).toggleStyle(.checkbox)
                }
            }
            addButton("Add Volume") { model.volumes.append(.init()) }
        }
    }

    private func envSection(_ model: EditContainerModel) -> some View {
        Section {
            ForEach($model.env) { $row in
                rowControls(error: model.envError(row), onRemove: { remove(\.env, row.id) }) {
                    TextField("KEY", text: $row.key).frame(width: 160)
                        .accessibilityIdentifier("editSheet.env.key")
                    Text(verbatim: "=").foregroundStyle(.secondary)
                    TextField("value", text: $row.value)
                        .accessibilityIdentifier("editSheet.env.value")
                }
            }
            addButton("Add Variable") { model.env.append(.init()) }
                .accessibilityIdentifier("editSheet.env.add")
        } header: {
            Text("Environment")
        } footer: {
            Text("Includes image defaults (PATH, etc.).").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Existing networks, plus a name already in the row that isn't one any more.
    private func networkNames(including current: String) -> [String] {
        let names = Set(app.model.networks.map(\.name))
        return (current.isEmpty || names.contains(current) ? names : names.union([current])).sorted()
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func rowControls<Fields: View>(error: String?, onRemove: @escaping () -> Void,
                                           @ViewBuilder fields: () -> Fields) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                fields()
                Spacer(minLength: 4)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .textFieldStyle(.roundedBorder)
            // Each field's name shows as its placeholder; the row reads left to right.
            .labelsHidden()
            if let error {
                Text(error).font(.caption2).foregroundStyle(Tone.critical.text)
            }
        }
    }

    private func addButton(_ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: "plus") }
            .buttonStyle(.borderless)
    }

    private func remove<Row: Identifiable>(_ keyPath: ReferenceWritableKeyPath<EditContainerModel, [Row]>, _ id: Row.ID) {
        model[keyPath: keyPath].removeAll { $0.id == id }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error).font(.callout).foregroundStyle(Tone.critical.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("editSheet.cancel")
                Spacer()
                let changes = model.changeCount
                Text(changes == 0 ? "No changes" : "\(changes) changes")
                    .font(.callout).foregroundStyle(changes == 0 ? .secondary : Tone.info.text)
                    .monospacedDigit()
                Button {
                    apply()
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Recreate") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("editSheet.recreate")
                .disabled(isWorking || !model.isValid || model.changeCount == 0)
            }
        }
        .padding()
    }

    private func apply() {
        isWorking = true
        error = nil
        let edits = model.buildEdits()
        Task {
            do {
                try await app.engine.recreateContainer(container, edits: edits)
                isWorking = false
                onRecreated()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isWorking = false
            }
        }
    }
}
