import SwiftUI
import Observation
import ContainerKit

@MainActor
@Observable
final class VolumesViewModel {
    private let engine: any ContainerEngine
    private let model: EngineModel
    var error: String?
    var busy: Set<String> = []
    var newName = ""

    var volumes: [Volume] { model.volumes }
    /// Space actually used on disk, by volume name.
    private(set) var sizes: [String: Int64] = [:]

    /// Containers that mount `volume`.
    func usedBy(_ volume: Volume) -> [String] {
        model.containers.filter { ($0.configuration.mounts ?? []).contains { $0.volumeName == volume.name } }
            .map(\.id).sorted()
    }

    /// Containers that mount `volume`, with where they mount it.
    func mounts(of volume: Volume) -> [(container: Container, path: String)] {
        model.containers.filter { $0.configuration.labels[VolumeHelper.label] == nil }.compactMap { container in
            (container.configuration.mounts ?? []).first { $0.volumeName == volume.name }.map { (container, $0.destination) }
        }
        .sorted { $0.container.id < $1.container.id }
    }

    /// The compose project a volume belongs to, by its name (`shop_data`,
    /// `shop-data`): compose names volumes after their project.
    func project(of volume: Volume) -> String? {
        let projects = addedProjects.union(model.containers.compactMap(ContainerList.project(of:)))
        return projects.filter { volume.name.hasPrefix($0 + "_") || volume.name.hasPrefix($0 + "-") }
            .max { $0.count < $1.count }
    }

    /// Compose projects added here (read with the sizes, not on every redraw).
    private var addedProjects: Set<String> = []

    func loadSizes() async {
        addedProjects = Set(StackStore.load().map(\.name))
        for volume in volumes {
            if let size = try? await engine.volumeDiskUsage(volume.name) { sizes[volume.name] = size }
        }
    }
    var isLoading: Bool { model.isLoading(.volumes) }

    private let cli: ContainerCLI?

    init(engine: any ContainerEngine, model: EngineModel, cli: ContainerCLI? = nil) {
        self.engine = engine
        self.model = model
        self.cli = cli
    }

    // MARK: - Backups and browsing (through short-lived helper containers)

    /// Save `volume` as a .tar.gz at `file`.
    @discardableResult
    func backUp(_ volume: Volume, to file: URL) async -> Bool {
        guard let cli else { return false }
        busy.insert(volume.id); defer { busy.remove(volume.id) }
        do {
            try await cli.run(VolumeHelper.backupArguments(volume: volume.name, folder: file.deletingLastPathComponent().path,
                                                            file: file.lastPathComponent))
            notice = String(localized: "\(volume.name) saved to \(file.lastPathComponent)")
            return true
        } catch {
            self.error = String(localized: "Couldn't back up \(volume.name): \(error.localizedDescription)")
            return false
        }
    }

    /// Save every volume into `folder`, one archive each.
    func backUpAll(to folder: URL) async { await backUp(volumes, to: folder) }

    /// Save each of `chosen` into `folder`; returns the ones saved.
    @discardableResult
    func backUp(_ chosen: [Volume], to folder: URL) async -> [Volume] {
        let stamp = VolumeHelper.stamp(Date())
        var saved: [Volume] = []
        for volume in chosen where await backUp(volume, to: folder.appending(path: "\(volume.name)-\(stamp).tar.gz")) {
            saved.append(volume)
        }
        notice = String(localized: "\(saved.count) volumes saved to \(folder.lastPathComponent)")
        return saved
    }

    /// A running container with `volume` mounted at /data, for the Files view.
    func startBrowsing(_ volume: Volume) async -> String? {
        guard let cli else { return nil }
        let name = VolumeHelper.browserName(volume.name)
        // Helpers left from another volume, or from before the app quit.
        await stopLeftoverHelpers(except: name)
        if model.containers.contains(where: { $0.id == name && $0.state.isRunning }) { return name }
        do {
            try await cli.run(VolumeHelper.browseArguments(volume: volume.name, name: name))
            await model.refresh([.containers])
            return name
        } catch {
            self.error = String(localized: "Couldn't open \(volume.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Stop a browsing helper (it was started with --rm, so it goes).
    func stopBrowsing(_ name: String) async {
        try? await cli?.run(["stop", name])
        await model.refresh([.containers])
    }

    /// Helpers left from a previous run (the app quit while browsing).
    func stopLeftoverHelpers(except keep: String?) async {
        for container in model.containers where container.configuration.labels[VolumeHelper.label] == "browse"
            && container.id != keep && container.state.isRunning {
            await stopBrowsing(container.id)
        }
    }

    var notice: String?

    func load() async {
        await model.refresh([.volumes])
        error = model.errorMessage(.volumes)
    }

    /// `true` once created.
    @discardableResult
    func create() async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        defer { Task { await model.refresh([.volumes]) } }
        do {
            try await engine.createVolume(name)
            newName = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ volume: Volume) async { await delete([volume]) }

    /// Delete each; the first failure is shown, the rest still go.
    func delete(_ volumes: [Volume]) async {
        let ids = Set(volumes.map(\.id))
        busy.formUnion(ids); defer { busy.subtract(ids) }
        for volume in volumes {
            do { try await engine.deleteVolume(volume.name) }
            catch { if self.error == nil { self.error = error.localizedDescription } }
        }
        await model.refresh([.volumes, .diskUsage])
    }

    func prune() async {
        do { try await engine.pruneVolumes() }
        catch { self.error = error.localizedDescription }
        await model.refresh([.volumes, .diskUsage])
    }
}

struct VolumesView: View {
    @Environment(AppState.self) private var app
    @State private var model: VolumesViewModel?
    @State private var confirmPrune = false
    @State private var pendingDelete: Volume?
    @State private var selection = CardSelection()
    /// Several selected volumes to delete, once confirmed.
    @State private var pendingDeletes: [Volume] = []
    @State private var creating = false
    /// The volume whose files show below the cards, and the container they're read through.
    @State private var browsing: Browsing?

    struct Browsing: Equatable {
        let volume: String
        let container: String
        let path: String
        /// A helper started for this (removed when browsing ends).
        let helper: Bool
    }

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle("Storage that outlives containers")
        .confirmationDialog("Remove all unused volumes?", isPresented: $confirmPrune, titleVisibility: .visible) {
            Button("Remove Unused", role: .destructive) { Task { await model?.prune() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingDelete.map { String(localized: "Delete volume “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { volume in
            // The safer way first: save it, then delete only if the save worked.
            Button("Back Up First…") {
                pendingDelete = nil
                if let model { backUp(volume, model, thenDelete: true) }
            }
            Button("Delete", role: .destructive) {
                Task { await model?.delete(volume) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { volume in
            Text(deleteMessage(volume))
        }
        .confirmationDialog(String(localized: "Delete \(pendingDeletes.count) volumes?"),
                            isPresented: Binding(get: { !pendingDeletes.isEmpty }, set: { if !$0 { pendingDeletes = [] } }),
                            titleVisibility: .visible) {
            // The safer way first: save them, then delete the ones saved.
            Button("Back Up First…") {
                let volumes = pendingDeletes
                pendingDeletes = []
                if let model { backUp(volumes, model, thenDelete: true) }
            }
            Button("Delete", role: .destructive) {
                let volumes = pendingDeletes
                pendingDeletes = []
                selection.clear()
                Task { await model?.delete(volumes) }
            }
            Button("Cancel", role: .cancel) { pendingDeletes = [] }
        } message: {
            Text(deleteMessage(pendingDeletes))
        }
        .sheet(isPresented: $creating) {
            if let model { NewVolumeSheet(model: model) }
        }
        .onAppear { if model == nil { model = VolumesViewModel(engine: app.engine, model: app.model, cli: app.cli) } }
        .task { await app.model.observe([.volumes, .containers]) }
        .task(id: model?.volumes.map(\.name) ?? []) { await model?.loadSizes() }
    }

    private func selected(_ model: VolumesViewModel) -> [Volume] {
        model.volumes.filter { selection.contains($0.id) }.sorted { $0.name < $1.name }
    }

    /// One volume asks by name (with its own Back Up First); several, by count.
    private func askToDelete(_ model: VolumesViewModel) {
        let chosen = selected(model)
        if chosen.count == 1 { pendingDelete = chosen[0] } else if !chosen.isEmpty { pendingDeletes = chosen }
    }

    private func content(_ model: VolumesViewModel) -> some View {
        let order = model.volumes.map(\.name).sorted().compactMap { name in model.volumes.first { $0.name == name }?.id }
        return SelectionScroll(selection: $selection, all: order, onDelete: { askToDelete(model) }) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                LearnNote("**Volumes keep data safe** when a container is recreated or updated. Delete a container — its volume stays. Folders from your Mac aren't volumes; they're listed on each container's page.")
                if model.volumes.isEmpty && !model.isLoading {
                    ContentUnavailableView {
                        Label("No Volumes", systemImage: "externaldrive")
                    } description: {
                        Text("A volume appears when a container or compose project asks for one, or when you create it.")
                    } actions: {
                        Button("New Volume…") { creating = true }
                    }
                    .accessibilityIdentifier("volumes.emptyState")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: DS.Spacing.l, alignment: .top)],
                              spacing: DS.Spacing.l) {
                        ForEach(model.volumes.sorted { $0.name < $1.name }) { volume in
                            card(volume, model)
                                .selectableCard(volume.id, in: $selection, order: order, cornerRadius: DS.Radius.panel) {
                                    browse(volume, through: model.mounts(of: volume).first { $0.container.state.isRunning }, model)
                                }
                        }
                    }
                    .accessibilityIdentifier("volumes.list")
                    if let browsing { browser(browsing, model) }
                }
            }
            .padding(DS.Spacing.l)
        }
        .background(DS.canvas)
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                SelectionBar(count: selection.count, onClear: { selection.clear() }) {
                    Button("Back Up…") { backUp(selected(model), model) }
                        .help("Save them as .tar.gz archives in a folder you choose")
                    Button("Delete…", role: .destructive) { askToDelete(model) }
                }
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.positive.text)
                    .floatingPanel()
                    .padding(DS.Spacing.l)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        model.notice = nil
                    }
            }
        }
        .onChange(of: model.volumes.map(\.name), initial: true) { _, names in
            guard let name = app.browseVolume, names.contains(name),
                  let volume = model.volumes.first(where: { $0.name == name }) else { return }
            app.browseVolume = nil
            let mount = model.mounts(of: volume).first { $0.container.state.isRunning }
            browse(volume, through: mount, model)
        }
        .onDisappear { endBrowsing(model) }
        .staleDataBanner(.volumes)
        .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Remove Unused") { confirmPrune = true }
                        .accessibilityIdentifier("volumes.prune")
                    Button("Refresh") { Task { await model.load() } }
                        .accessibilityIdentifier("volumes.refresh")
                        .disabled(model.isLoading)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More")
                .menuIndicator(.hidden)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Back Up All…") { backUpAll(model) }
                    .help("Save every volume as a .tar.gz archive in a folder you choose")
                    .disabled(model.volumes.isEmpty)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("New Volume…") { creating = true }
                    .buttonStyle(.borderedProminent)
                    .help("Create a volume")
                    .accessibilityIdentifier("volumes.new")
            }
        }
    }

    private func card(_ volume: Volume, _ model: VolumesViewModel) -> some View {
        let mounts = model.mounts(of: volume)
        let size = model.sizes[volume.name]
        let browsable = mounts.first { $0.container.state.isRunning }
        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(mounts.isEmpty && model.project(of: volume) == nil ? Tone.warning.fill : DS.accent)
                    .accessibilityHidden(true)
                Text(volume.name).font(.system(.headline, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.Spacing.s)
                Text(size.map(Format.bytes) ?? "—").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .help(volume.configuration.sizeInBytes.map { String(localized: "Space used on disk; it can grow to \(Format.bytes($0))") }
                          ?? String(localized: "Space used on disk"))
                if model.busy.contains(volume.id) { ProgressView().controlSize(.small) }
            }
            if mounts.isEmpty, let project = model.project(of: volume) {
                Text("Kept for **\(project)** — used again when it starts").font(.callout).foregroundStyle(.secondary)
            } else if mounts.isEmpty {
                Text("Not used by anything").font(.callout).foregroundStyle(Tone.warning.text)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mounts, id: \.container.id) { mount in
                        Button { app.openContainer(mount.container.id) } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                StatusDot(tone: mount.container.state.isRunning ? .positive : .inactive, size: 6)
                                Text(mount.container.id).font(.callout)
                                Text("at \(mount.path)").font(DS.Font.monoSmall).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open \(mount.container.id)")
                    }
                }
            }
            HStack(spacing: DS.Spacing.m) {
                Button("Browse Files") { browse(volume, through: browsable, model) }
                    .help(browsable.map { String(localized: "See its files through \($0.container.id), which mounts it at \($0.path)") }
                          ?? String(localized: "See its files (a small helper container opens it while you look)"))
                Button("Back Up…") { backUp(volume, model) }
                    .help("Save it as a .tar.gz archive")
                Spacer(minLength: 0)
                Button("Delete…", role: .destructive) { pendingDelete = volume }
                    .foregroundStyle(Tone.critical.text)
                    .accessibilityLabel("Delete volume \(volume.name)")
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .panel()
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .strokeBorder(browsing?.volume == volume.name ? DS.accent : .clear, lineWidth: 2))
        .contextMenu {
            Button("Copy Mount Argument") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("--volume \(volume.name):/data", forType: .string)
            }
            if selection.contains(volume.id) && selection.count > 1 {
                Button("Back Up \(selection.count) Volumes…") { backUp(selected(model), model) }
                Button("Delete \(selection.count) Volumes…", role: .destructive) { askToDelete(model) }
            } else {
                Button("Delete…", role: .destructive) { pendingDelete = volume }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(volume.name)
    }

    // MARK: - Browsing and backups

    private func browse(_ volume: Volume, through mount: (container: Container, path: String)?, _ model: VolumesViewModel) {
        endBrowsing(model)
        if let mount {
            app.pendingFilesPath = mount.path
            browsing = Browsing(volume: volume.name, container: mount.container.id, path: mount.path, helper: false)
            return
        }
        Task {
            guard let helper = await model.startBrowsing(volume) else { return }
            app.pendingFilesPath = "/data"
            browsing = Browsing(volume: volume.name, container: helper, path: "/data", helper: true)
        }
    }

    private func endBrowsing(_ model: VolumesViewModel) {
        guard let current = browsing else { return }
        browsing = nil
        if current.helper { Task { await model.stopBrowsing(current.container) } }
    }

    private func browser(_ browsing: Browsing, _ model: VolumesViewModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Text(browsing.volume).font(.headline)
                Text("· files").foregroundStyle(.secondary)
                Spacer()
                Text("Browse and copy files out without a shell. Drop files here to copy them in.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Done") { endBrowsing(model) }
                    .buttonStyle(.automatic)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DS.Spacing.m)
            Divider()
            if let container = app.model.containers.first(where: { $0.id == browsing.container }) {
                FilesTab(container: container)
                    .id(browsing.container + browsing.path)
            } else {
                ProgressView("Opening \(browsing.volume)…").frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(height: 380, alignment: .top)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.raised))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel))
        .hairline(RoundedRectangle(cornerRadius: DS.Radius.panel), DS.separator.opacity(0.5))
        .accessibilityIdentifier("volumes.browser")
    }

    private func deleteMessage(_ volumes: [Volume]) -> String {
        let users = Set(volumes.flatMap { model?.usedBy($0) ?? [] }).sorted()
        let sizes = volumes.compactMap { model?.sizes[$0.name] }
        let size = sizes.count == volumes.count ? Format.bytes(sizes.reduce(0, +)) : nil
        let names = users.joined(separator: ", ")
        switch (size, users.isEmpty) {
        case (nil, true): return String(localized: "Their data will be gone for good.")
        case (let size?, true): return String(localized: "\(size) of data will be gone for good.")
        case (nil, false): return String(localized: "Their data, used by \(names), will be gone for good. They stop working until they are recreated.")
        case (let size?, false): return String(localized: "\(size) of data, used by \(names), will be gone for good. They stop working until they are recreated.")
        }
    }

    private func deleteMessage(_ volume: Volume) -> String {
        let users = model?.usedBy(volume) ?? []
        let size = model?.sizes[volume.name].map { Format.bytes($0) }
        let names = users.joined(separator: ", ")
        switch (size, users.count) {
        case (nil, 0):
            return String(localized: "Its data will be gone for good.")
        case (let size?, 0):
            return String(localized: "\(size) of data will be gone for good.")
        case (nil, 1):
            return String(localized: "Its data, used by \(names), will be gone for good. It stops working until it is recreated.")
        case (let size?, 1):
            return String(localized: "\(size) of data, used by \(names), will be gone for good. It stops working until it is recreated.")
        case (nil, _):
            return String(localized: "Its data, used by \(names), will be gone for good. They stop working until they are recreated.")
        case (let size?, _):
            return String(localized: "\(size) of data, used by \(names), will be gone for good. They stop working until they are recreated.")
        }
    }

    private func backUp(_ volume: Volume, _ model: VolumesViewModel, thenDelete: Bool = false) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Back Up \(volume.name)")
        panel.nameFieldStringValue = "\(volume.name)-\(VolumeHelper.stamp(Date())).tar.gz"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await model.backUp(volume, to: url), thenDelete { await model.delete(volume) }
        }
    }

    /// Save `volumes` into a folder the user picks; then delete the ones saved.
    private func backUp(_ volumes: [Volume], _ model: VolumesViewModel, thenDelete: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Back Up \(volumes.count) Volumes")
        panel.prompt = String(localized: "Back Up Here")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let saved = await model.backUp(volumes, to: folder)
            if thenDelete {
                selection.clear()
                await model.delete(saved)
            }
        }
    }

    private func backUpAll(_ model: VolumesViewModel) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Back Up All Volumes")
        panel.prompt = String(localized: "Back Up Here")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.backUpAll(to: folder) }
    }
}

/// A name for a new volume.
private struct NewVolumeSheet: View {
    let model: VolumesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("New Volume").font(.title2.weight(.semibold))
            Text("Mount it into a container to keep that container's data when it's recreated.")
                .foregroundStyle(.secondary)
            TextField("Name", text: Binding(get: { model.newName }, set: { model.newName = $0 }), prompt: Text("e.g. pgdata"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("volumes.nameField")
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.newName.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    .accessibilityIdentifier("volumes.create")
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 420)
    }

    private func create() {
        Task {
            working = true
            if await model.create() { dismiss() }
            working = false
        }
    }
}

/// Commands for the helper containers that back up and open volumes.
enum VolumeHelper {
    static let label = "com.irekobox.helper"
    static let image = "docker.io/library/alpine:latest"

    /// `container run --rm` that writes `volume` as `folder/file` (tar.gz).
    static func backupArguments(volume: String, folder: String, file: String) -> [String] {
        ["run", "--rm", "--label", "\(label)=backup",
         "--volume", "\(volume):/data:ro", "--volume", "\(folder):/backup",
         image, "tar", "czf", "/backup/\(file)", "-C", "/data", "."]
    }

    /// `container run -d --rm` that keeps `volume` mounted at /data to look into.
    static func browseArguments(volume: String, name: String) -> [String] {
        ["run", "-d", "--rm", "--name", name, "--label", "\(label)=browse",
         "--volume", "\(volume):/data", image, "sleep", "infinity"]
    }

    /// "irekobox-files-pgdata", kept to the characters a name allows.
    static func browserName(_ volume: String) -> String {
        "irekobox-files-" + String(volume.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" })
    }

    /// "2026-10-27-0130" for archive names.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }
}
