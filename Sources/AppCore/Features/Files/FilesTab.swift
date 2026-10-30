import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ContainerKit

/// Files tab: browse a running container's filesystem, read the selected
/// file below the list (or in Quick Look), download, and drop files in to
/// upload. Says when a folder really lives on the Mac or in a volume.
struct FilesTab: View {
    @Environment(AppState.self) private var app
    let container: Container

    @State private var model: FilesModel?
    @State private var selection: Set<String> = []
    @State private var previewURL: URL?
    @State private var dropTargeted = false
    @State private var choosingUpload = false
    @State private var preview: Preview = .none

    enum Preview: Equatable {
        case none, loading, text(String), binary, failed(String)
    }

    private var mounts: [Container.Mount] { container.configuration.mounts ?? [] }

    /// The one regular file selected, if that's the selection.
    private func selectedFile(_ model: FilesModel) -> ContainerFile? {
        guard selection.count == 1 else { return nil }
        return model.entries.first { selection.contains($0.path) && $0.kind == .file }
    }

    var body: some View {
        Group {
            if !container.state.isRunning {
                ContentUnavailableView("Container Not Running", systemImage: "folder",
                                       description: Text("Files are read through the running container. Start it to browse."))
            } else if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(container.id)-\(container.state.isRunning)") {
            guard container.state.isRunning else { return }
            if model?.containerID != container.id {
                // Start where the container's process runs (WORKDIR), like `exec` does.
                let workingDirectory = container.configuration.initProcess.workingDirectory
                let start = app.pendingFilesPath ?? (workingDirectory.isEmpty ? "/" : workingDirectory)
                app.pendingFilesPath = nil
                model = FilesModel(containerID: container.id, engine: app.engine, path: start)
            }
            await model?.load()
        }
    }

    // MARK: - Layout

    private func content(_ model: FilesModel) -> some View {
        VStack(spacing: 0) {
            bar(model)
            Divider()
            if let mount = ContainerFiles.mount(containing: model.path, in: mounts) {
                mountBanner(mount)
                Divider()
            }
            if let message = model.listingError {
                ContentUnavailableView("Can't list \(model.path)", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            } else {
                // One split view either way, so the list keeps its scroll position.
                VSplitView {
                    table(model).frame(minHeight: 140)
                    if let file = selectedFile(model) {
                        previewPane(file, model).frame(minHeight: 240)
                    }
                }
            }
            footer(model)
        }
        .quickLookPreview($previewURL)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.upload(urls) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay(Text("Copy into \(model.path)").font(.headline).padding(DS.Spacing.s)
                        .background(.regularMaterial, in: Capsule()))
                    .padding(DS.Spacing.s)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $choosingUpload, allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.upload(urls) } }
        }
        .task(id: selectedFile(model)) {
            guard let file = selectedFile(model) else { preview = .none; return }
            preview = .loading
            do {
                let text = try await model.previewText(file)
                guard !Task.isCancelled else { return }
                preview = text.map(Preview.text) ?? .binary
            } catch is CancellationError {
            } catch {
                preview = .failed(error.localizedDescription)
            }
        }
        .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
        .accessibilityIdentifier("files.tab")
    }

    private func bar(_ model: FilesModel) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Button { Task { await model.open(ContainerFiles.parent(of: model.path)) } } label: {
                Image(systemName: "chevron.up")
            }
            .help("Enclosing folder")
            .accessibilityLabel("Enclosing folder")
            .disabled(model.path == "/")

            // Path bar: every ancestor is a click away.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(ContainerFiles.ancestors(of: model.path), id: \.self) { ancestor in
                        if ancestor != "/" {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button(ancestor == "/" ? "/" : (ancestor as NSString).lastPathComponent) {
                            Task { await model.open(ancestor) }
                        }
                        .buttonStyle(.plain)
                        .font(DS.Font.monoSmall)
                        .foregroundStyle(ancestor == model.path ? .primary : .secondary)
                    }
                }
            }
            .accessibilityIdentifier("files.path")

            Spacer()
            Button { choosingUpload = true } label: { Label("Upload…", systemImage: "square.and.arrow.up") }
                .help("Copy files from your Mac into \(model.path) (or drop them here)")
            Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .disabled(model.transfer != nil)
    }

    /// Where this folder's files really are: a folder on the Mac, or a volume.
    private func mountBanner(_ mount: Container.Mount) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if let volume = mount.volumeName {
                Image(systemName: "externaldrive").foregroundStyle(DS.accent).accessibilityHidden(true)
                Text("This folder is the volume **\(volume)** — its files stay when the container is removed.")
                Spacer(minLength: 0)
                Button("Show Volumes") { app.section = .volumes }
                    .buttonStyle(.link)
            } else if let source = mount.source {
                Image(systemName: "laptopcomputer").foregroundStyle(DS.accent).accessibilityHidden(true)
                Text("This folder comes from **\((source as NSString).abbreviatingWithTildeInPath)** on your Mac — changes show up on both sides.")
                Spacer(minLength: 0)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: source)])
                }
                .buttonStyle(.link)
                .disabled(!FileManager.default.fileExists(atPath: source))
            }
            if mount.isReadOnly {
                Text("Read-only").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.s).padding(.vertical, 2)
                    .background(Capsule().fill(DS.subtleFill))
            }
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.accent.opacity(0.06))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files.mount")
    }

    private func previewPane(_ file: ContainerFile, _ model: FilesModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(file.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(Format.bytes(file.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Quick Look") { Task { await self.preview(file, model) } }
                Button("Download") { Task { await download([file], model) } }
            }
            .controlSize(.small)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)
            Divider()
            Group {
                switch preview {
                case .none, .loading:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text):
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            Text(text.isEmpty ? String(localized: "Empty file") : text)
                                .font(DS.Font.monoSmall)
                                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize()
                            if file.size > Int64(ContainerFiles.previewLength) {
                                Text("Showing the first \(Format.bytes(ContainerFiles.previewLength)) — Quick Look or Download for the rest.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.l)
                    }
                case .binary:
                    ContentUnavailableView("Not a Text File", systemImage: "doc",
                                           description: Text("Press Space for Quick Look, or download it."))
                case .failed(let message):
                    ContentUnavailableView("Can't Read \(file.name)", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.raised)
        }
        .accessibilityIdentifier("files.preview")
    }

    private func table(_ model: FilesModel) -> some View {
        Table(model.entries, selection: $selection) {
            TableColumn("Name") { file in
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: icon(file))
                        .foregroundStyle(file.kind == .directory ? DS.accent : .secondary)
                        .frame(width: 16)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    // A folder where a Mac folder or a volume is mounted.
                    if file.kind == .directory, let mount = mounts.first(where: { $0.destination == file.path }) {
                        Text(mount.volumeName.map { String(localized: "volume \($0)") } ?? String(localized: "from your Mac"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Size") { file in
                Text(file.kind == .file ? Format.bytes(file.size) : "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified") { file in
                Text(file.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Permissions") { file in
                Text(file.permissions).font(DS.Font.monoSmall).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            let files = model.entries.filter { paths.contains($0.path) }
            if files.count == 1, let file = files.first, file.kind != .directory {
                Button("Quick Look") { Task { await preview(file, model) } }
            }
            if !files.isEmpty {
                Button("Download to Downloads") { Task { await download(files, model) } }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
                }
            }
        } primaryAction: { paths in
            guard paths.count == 1, let file = model.entries.first(where: { paths.contains($0.path) }) else { return }
            if file.kind == .directory || file.kind == .link {
                Task { await model.open(file.path) }
            } else {
                Task { await preview(file, model) }
            }
        }
        .overlay {
            if model.entries.isEmpty && !model.isLoading {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .onKeyPress(.space) {
            guard selection.count == 1, let file = model.entries.first(where: { selection.contains($0.path) }),
                  file.kind != .directory else { return .ignored }
            Task { await preview(file, model) }
            return .handled
        }
        .accessibilityIdentifier("files.list")
    }

    private func footer(_ model: FilesModel) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if let transfer = model.transfer {
                ProgressView().controlSize(.small)
                Text("Copying \(transfer)…")
            } else {
                Text("\(model.entries.count) items")
                Text("· Return opens, Space previews, drop files to upload").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .background(.bar)
    }

    // MARK: - Actions

    private func icon(_ file: ContainerFile) -> String {
        switch file.kind {
        case .directory: return "folder.fill"
        case .link: return "arrow.turn.up.right"
        case .file, .other: return "doc"
        }
    }

    /// Copy to a private temporary folder and hand it to Quick Look.
    private func preview(_ file: ContainerFile, _ model: FilesModel) async {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Irekobox-Preview/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previewURL = await model.download(file, into: folder)
    }

    private func download(_ files: [ContainerFile], _ model: FilesModel) async {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        var saved: [URL] = []
        for file in files {
            if let url = await model.download(file, into: downloads) { saved.append(url) }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }
}
