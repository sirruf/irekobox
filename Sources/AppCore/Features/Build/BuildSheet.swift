import SwiftUI
import UniformTypeIdentifiers

/// Build an image from a folder with a Dockerfile, watch its steps live,
/// then run it or push it. Remembers the last folder.
struct BuildSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model: BuildViewModel?
    @State private var importingDockerfile = false
    @State private var importingContext = false
    /// Set when the user chose Push… after a build: the push form takes over.
    @State private var pushSource: String?
    @AppStorage("build.runWhenDone") private var runWhenDone = true
    @AppStorage("build.lastContext") private var lastContext = ""

    var body: some View {
        Group {
            if let pushSource {
                PushSheet(reference: pushSource)
            } else if let model {
                switch model.phase {
                case .form: form(model)
                case .running, .finished:
                    BuildProgressView(model: model, onBack: { model.phase = .form }, onClose: { dismiss() },
                                      onPush: { pushSource = $0 }, onRun: run)
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: 560, height: 480)
        .onAppear {
            if model == nil {
                let vm = BuildViewModel(engine: app.engine)
                if vm.contextPath.isEmpty, !lastContext.isEmpty,
                   FileManager.default.fileExists(atPath: lastContext) {
                    vm.contextPath = lastContext
                }
                model = vm
            }
        }
        .onChange(of: model?.succeeded) { _, succeeded in
            guard succeeded == true, runWhenDone, let tag = model?.builtTag else { return }
            run(tag)
        }
    }

    private func run(_ tag: String) {
        dismiss()
        app.requestRun(image: tag)
    }

    // MARK: - Form

    private func form(_ model: BuildViewModel) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    pathRow("Folder", text: Binding(get: { model.contextPath }, set: { model.contextPath = $0 }),
                            placeholder: "the folder with your app") { importingContext = true }
                    if let note = folderNote(model) {
                        Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(note.ok ? Tone.positive.text : Tone.warning.text)
                    }
                    pathRow("Dockerfile", text: Binding(get: { model.dockerfilePath }, set: { model.dockerfilePath = $0 }),
                            placeholder: "optional — the folder's Dockerfile") { importingDockerfile = true }
                } header: {
                    Text("Build Image").font(.title3.weight(.semibold))
                } footer: {
                    Text("Everything in the folder is sent to the builder, so keep big files out with a .dockerignore.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Name and tag") {
                    TextField("Name", text: Binding(get: { model.imageName }, set: { model.imageName = $0 }),
                              prompt: Text(verbatim: "shop/api"))
                    TextField("Tag", text: Binding(get: { model.tag }, set: { model.tag = $0 }))
                }
                Section("Options") {
                    Toggle("Run it when done", isOn: $runWhenDone)
                    Toggle("No cache", isOn: Binding(get: { model.noCache }, set: { model.noCache = $0 }))
                        .help("Run every step again instead of reusing earlier results")
                    Toggle("Also build amd64 (Rosetta)", isOn: Binding(get: { model.alsoAMD64 }, set: { model.alsoAMD64 = $0 }))
                    if model.alsoAMD64 {
                        Text("amd64 needs the base image pulled for that platform first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("buildSheet.cancel")
                Spacer()
                Button("Build") {
                    lastContext = model.contextPath
                    Task { await model.startBuild() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("buildSheet.build")
                .disabled(!model.canBuild)
            }
            .padding()
        }
        .fileImporter(isPresented: $importingDockerfile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                model.dockerfilePath = url.path
                if model.contextPath.isEmpty { model.contextPath = url.deletingLastPathComponent().path }
            }
        }
        .fileImporter(isPresented: $importingContext, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.contextPath = url.path }
        }
    }

    /// Whether the folder has what a build needs.
    private func folderNote(_ model: BuildViewModel) -> (text: String, ok: Bool)? {
        let folder = model.contextPath.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (String(localized: "There's no folder here"), false)
        }
        if !model.dockerfilePath.isEmpty { return nil }
        let names = ["Dockerfile", "Containerfile", "dockerfile"]
        if names.contains(where: { FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }) {
            return (String(localized: "Has a Dockerfile"), true)
        }
        return (String(localized: "No Dockerfile in this folder — choose one below"), false)
    }

    private func pathRow(_ label: LocalizedStringKey, text: Binding<String>, placeholder: LocalizedStringKey, choose: @escaping () -> Void) -> some View {
        HStack {
            TextField(label, text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
            Button("Choose…", action: choose)
        }
    }
}

/// A build or push as it happens: step, stage, the output, and what to do next.
struct BuildProgressView: View {
    let model: BuildViewModel
    var onBack: () -> Void
    var onClose: () -> Void
    var onPush: ((String) -> Void)? = nil
    var onRun: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.operation).font(.headline)
                Spacer()
                if model.phase == .running {
                    if model.total > 0 {
                        Text("step \(model.step) of \(model.total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView().controlSize(.small)
                }
            }

            if let fraction = model.fraction {
                ProgressView(value: fraction) {
                    Text(stageLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView().progressViewStyle(.linear)
                    Text(stageLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            logView
            footer
        }
        .padding()
    }

    private var stageLabel: String {
        var label = model.currentStage.isEmpty ? String(localized: "Starting…") : model.currentStage
        if model.total > 0 { label = "[\(model.step)/\(model.total)] " + label }
        return label
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.logs) { line in
                        Text(line.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.text.contains("CACHED") ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: model.logs.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.phase == .finished {
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Tone.critical.text).font(.callout)
                    .textSelection(.enabled)
                HStack {
                    Button("Back", action: onBack)
                    Spacer()
                    Button("Close", action: onClose)
                }
            } else if model.succeeded {
                HStack {
                    Label(model.builtTag.map { String(localized: "Built \($0)") } ?? String(localized: "Done"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.positive.text).font(.callout)
                    Spacer()
                    if let tag = model.builtTag {
                        if let onPush {
                            Button { onPush(tag) } label: { Label("Push…", systemImage: "arrow.up.circle") }
                        }
                        if let onRun {
                            Button { onRun(tag) } label: { Label("Run", systemImage: "play.fill") }
                        }
                    }
                    Button("Close", action: onClose)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .help("The work goes on; its result shows up in Images")
            }
        }
    }
}
