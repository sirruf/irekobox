import SwiftUI
import Observation
import ContainerKit

@MainActor
@Observable
final class ImagesViewModel {
    private let engine: any ContainerEngine
    private let model: EngineModel
    var error: String?
    var busy: Set<String> = []
    var pullReference = ""
    /// Also fetch the linux/amd64 variant (for Rosetta or cross-arch builds).
    var pullAMD64 = false
    private(set) var isPulling = false
    private(set) var pullProgress: PullProgress?
    /// What the pull field offers for what's typed.
    let suggester: ImageSuggester
    var suggestions: [PullSuggestion] { suggester.suggestions }
    var suggestionNote: String? { suggester.note }

    var images: [ContainerImage] { model.images }
    var isLoading: Bool { model.isLoading(.images) }

    init(engine: any ContainerEngine, model: EngineModel,
         search: @escaping @Sendable (String, Int) async throws -> [SearchResult] = DockerHubSearch.search,
         registry: RegistryClient = RegistryClient()) {
        self.engine = engine
        self.model = model
        self.suggester = ImageSuggester(search: search, registry: registry)
    }

    /// Container ids using each image reference.
    var usage: [String: [String]] {
        Dictionary(grouping: model.containers, by: { $0.configuration.image.reference })
            .mapValues { $0.map(\.id).sorted() }
    }

    func usedBy(_ image: ContainerImage) -> [String] { usage[image.reference] ?? [] }

    /// User images no container uses — what "Remove unused" deletes.
    var unused: [ContainerImage] {
        let used = Set(model.containers.map { $0.configuration.image.reference })
        return images.filter { !$0.isSystem && !used.contains($0.reference) }
    }

    func load() async {
        await model.refresh([.images])
        error = model.errorMessage(.images)
    }

    /// Pull the native platform (plus amd64 when asked), with progress.
    func pull() async {
        var reference = pullReference.trimmingCharacters(in: .whitespaces)
        if reference.hasSuffix(":") { reference.removeLast() }
        guard !reference.isEmpty, !isPulling else { return }
        suggester.clear()
        isPulling = true
        pullProgress = nil
        defer { isPulling = false; pullProgress = nil }
        var lastLines: [String] = []
        do {
            let platforms = pullAMD64 ? ["linux/arm64", "linux/amd64"] : ["linux/arm64"]
            for platform in platforms {
                for try await line in engine.pullImageWithProgress(reference, platform: platform) {
                    if let progress = PullProgress.parse(line) {
                        pullProgress = progress
                    } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        lastLines = Array((lastLines + [line]).suffix(3))
                    }
                }
            }
            pullReference = ""
        } catch {
            let detail = lastLines.last { $0.lowercased().contains("error") } ?? error.localizedDescription
            self.error = detail
        }
        await model.refresh([.images, .diskUsage])
    }

    /// Refresh `suggestions` for what's typed, after a short pause.
    func suggest() {
        guard !isPulling else { return suggester.clear() }
        suggester.suggest(pullReference)
    }

    func loadSuggestions(for text: String) async {
        await suggester.load(for: text)
    }

    func delete(_ image: ContainerImage) async { await delete([image]) }

    /// Delete each; the first failure is shown, the rest still go.
    func delete(_ images: [ContainerImage]) async {
        let ids = Set(images.map(\.id))
        busy.formUnion(ids); defer { busy.subtract(ids) }
        for image in images {
            do { try await engine.deleteImage(image.reference, force: false) }
            catch { if self.error == nil { self.error = error.localizedDescription } }
        }
        await model.refresh([.images, .diskUsage])
    }

    func prune(all: Bool) async {
        do { try await engine.pruneImages(all: all) }
        catch { self.error = error.localizedDescription }
        await model.refresh([.images, .diskUsage])
    }
}

/// Images: what's on this Mac, what uses it, and pulling more.
struct ImagesView: View {
    @Environment(AppState.self) private var app
    @State private var model: ImagesViewModel?
    @State private var confirmPrune = false
    @State private var showBuild = false
    @State private var showPull = false
    enum Shown: String { case all, inUse, unused }
    @State private var shown: Shown = .all
    @State private var pushTarget: PushTarget?
    @State private var pendingDelete: ContainerImage?
    @State private var selection = CardSelection()
    /// Several selected images to delete, once confirmed.
    @State private var pendingDeletes: [ContainerImage] = []
    @State private var search = ""
    @State private var sortOrder: [KeyPathComparator<ImageRow>] = [.init(\.name)]
    /// Images `container` uses itself (VM init, builder) are hidden unless asked for.
    @AppStorage("showSystemImages") private var showSystem = false

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .navigationTitle("Images")
        .navigationSubtitle("Templates that containers and machines start from")
        .onAppear { if model == nil { model = ImagesViewModel(engine: app.engine, model: app.model) } }
        .task { await app.model.observe([.images, .containers, .diskUsage]) }
    }

    private func rows(_ model: ImagesViewModel) -> [ImageRow] {
        let usage = model.usage
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.images
            .filter { showSystem || !$0.isSystem }
            .filter { query.isEmpty || $0.reference.lowercased().contains(query) }
            .map { ImageRow(image: $0, usedBy: usage[$0.reference] ?? []) }
            .sorted(using: sortOrder)
    }

    private func content(_ model: ImagesViewModel) -> some View {
        let rows = rows(model)
        return VStack(spacing: 0) {
            if model.isPulling && !showPull {
                // A pull goes on after its sheet closes: its progress stays in sight.
                pullBar(model)
                Divider()
            }
            if rows.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    search.isEmpty ? Label("No Images", systemImage: "photo.stack") : Label("No Matches", systemImage: "photo.stack")
                } description: {
                    search.isEmpty ? Text("Pull an image above, or build one from a Dockerfile.") : Text("Nothing matches “\(search)”.")
                }
                .accessibilityIdentifier("images.emptyState")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cards(model, rows: rows)
            }
        }
        .background(DS.canvas)
        .searchable(text: $search, placement: .toolbar, prompt: "Image name")
        .staleDataBanner(.images)
        .toolbar { toolbar(model) }
        .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
        .confirmationDialog("Remove images?", isPresented: $confirmPrune, titleVisibility: .visible) {
            let unused = model.unused
            if !unused.isEmpty {
                Button("Remove \(unused.count) Unused (\(Format.bytes(unused.map(\.totalSize).reduce(0, +))))",
                       role: .destructive) { Task { await model.prune(all: true) } }
            }
            Button("Remove Untagged Layers Only", role: .destructive) { Task { await model.prune(all: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pruneMessage(model))
        }
        .confirmationDialog(pendingDelete.map { String(localized: "Delete image “\($0.shortName)”?") } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { image in
            Button("Delete", role: .destructive) {
                Task { await model.delete(image) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { image in
            let users = model.usedBy(image)
            users.isEmpty
                ? Text("It can be pulled again later.")
                : Text("Used by \(users.joined(separator: ", ")). They need it to start again.")
        }
        .confirmationDialog(String(localized: "Delete \(pendingDeletes.count) images?"),
                            isPresented: Binding(get: { !pendingDeletes.isEmpty }, set: { if !$0 { pendingDeletes = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let images = pendingDeletes
                pendingDeletes = []
                selection.clear()
                Task { await model.delete(images) }
            }
            Button("Cancel", role: .cancel) { pendingDeletes = [] }
        } message: {
            let users = pendingDeletes.flatMap { model.usedBy($0) }
            users.isEmpty
                ? Text("They can be pulled again later.")
                : Text("Used by \(users.joined(separator: ", ")). They need them to start again.")
        }
        .sheet(isPresented: $showPull) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                Text("Pull Image").font(.title2.weight(.semibold))
                Text("Download an image from Docker Hub or another registry. Start typing a name for suggestions.")
                    .foregroundStyle(.secondary)
                pullBar(model).padding(-DS.Spacing.l)
                HStack {
                    Spacer()
                    Button(model.isPulling ? String(localized: "Hide") : String(localized: "Close")) { showPull = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(DS.Spacing.xl)
            .frame(width: 560)
        }
        .sheet(isPresented: $showBuild, onDismiss: { Task { await model.load() } }) {
            BuildSheet().environment(app)
        }
        .sheet(item: $pushTarget) { target in
            PushSheet(reference: target.reference).environment(app)
        }
    }

    private func pullBar(_ model: ImagesViewModel) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                TextField("Pull an image, e.g. nginx:alpine",
                          text: Binding(get: { model.pullReference }, set: { model.pullReference = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("images.pullField")
                    .imageSuggestions(model.suggester)
                    .onChange(of: model.pullReference) { model.suggest() }
                    .onSubmit {
                        // Choosing a repository fills in "name:" to pick a tag next.
                        guard !model.pullReference.hasSuffix(":") else { return }
                        Task { await model.pull() }
                    }
                    .disabled(model.isPulling)
                Toggle("Also amd64", isOn: Binding(get: { model.pullAMD64 }, set: { model.pullAMD64 = $0 }))
                    .toggleStyle(.checkbox)
                    .help("Also fetch the linux/amd64 variant, for Rosetta or cross-architecture builds")
                Button { Task { await model.pull() } } label: {
                    Label("Pull", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("images.pullButton")
                .disabled(model.isPulling || model.pullReference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let note = model.suggestionNote, !model.isPulling {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.isPulling {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    if let overall = model.pullProgress?.overall {
                        ProgressView(value: overall)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text([model.pullProgress?.phase, model.pullProgress?.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityIdentifier("images.pullProgress")
            }
        }
        .padding(DS.Spacing.l)
    }

    // MARK: - Cards

    private func cards(_ model: ImagesViewModel, rows: [ImageRow]) -> some View {
        let used = shown == .unused ? [] : rows.filter { !$0.usedBy.isEmpty }
        let unused = shown == .inUse ? [] : rows.filter { $0.usedBy.isEmpty }
        let order = (used + unused).map(\.image.id)
        return SelectionScroll(selection: $selection, all: order, onDelete: { askToDelete(model) }) {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                if search.isEmpty { summary(model) }
                if !used.isEmpty { section("In use", used, order, model) }
                if !unused.isEmpty { section("Not used by anything", unused, order, model) }
            }
            .padding(DS.Spacing.l)
        }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                SelectionBar(count: selection.count, onClear: { selection.clear() }) {
                    Button("Delete", role: .destructive) { askToDelete(model) }
                }
            }
        }
        .accessibilityIdentifier("images.list")
    }

    /// One image asks by name; several, by count.
    private func askToDelete(_ model: ImagesViewModel) {
        let chosen = model.images.filter { selection.contains($0.id) }
        if chosen.count == 1 { pendingDelete = chosen[0] } else if !chosen.isEmpty { pendingDeletes = chosen }
    }

    private func section(_ title: LocalizedStringKey, _ rows: [ImageRow], _ order: [String], _ model: ImagesViewModel) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: DS.Spacing.m, alignment: .top)],
                      spacing: DS.Spacing.m) {
                ForEach(rows) { row in
                    imageCard(row, model)
                        .selectableCard(row.image.id, in: $selection, order: order, cornerRadius: DS.Radius.panel)
                }
            }
        }
    }

    /// Where the disk goes, and newer images for tags in use.
    private func summary(_ model: ImagesViewModel) -> some View {
        let user = model.images.filter { !$0.isSystem }
        let usage = model.usage
        let machines = user.filter(\.isMachineImage)
        let unused = user.filter { !$0.isMachineImage && (usage[$0.reference] ?? []).isEmpty }
        let inUse = user.filter { !$0.isMachineImage && !(usage[$0.reference] ?? []).isEmpty }
        func total(_ images: [ContainerImage]) -> Int { images.map(\.totalSize).reduce(0, +) }
        let parts: [(String, Int, Color)] = [(String(localized: "In use"), total(inUse), DS.accent),
                                             (String(localized: "Machine images"), total(machines), .purple),
                                             (String(localized: "Unused"), total(unused), .gray)]
        let sum = max(1, parts.map(\.1).reduce(0, +))
        let outdated = user.filter { app.imageUpdates.update(for: $0) }
        return HStack(alignment: .top, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack {
                    Text("Disk used by images").font(.headline)
                    Spacer()
                    Text(Format.bytes(sum)).foregroundStyle(.secondary).monospacedDigit()
                }
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                            Rectangle().fill(part.2)
                                .frame(width: max(4, (proxy.size.width - 4) * CGFloat(part.1) / CGFloat(sum)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 12)
                .accessibilityHidden(true)
                HStack(spacing: DS.Spacing.l) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                        HStack(spacing: DS.Spacing.xs) {
                            RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 9, height: 9)
                            Text(verbatim: "\(part.0) \(Format.bytes(part.1))")
                        }
                    }
                    Spacer(minLength: 0)
                    if total(unused) > 0 {
                        Button(String(localized: "Free \(Format.bytes(total(unused)))…", comment: "Button: free up disk space")) { confirmPrune = true }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .panel()
            .accessibilityElement(children: .combine)
            if !outdated.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("\(outdated.count) updates available")
                        .font(.headline).foregroundStyle(Tone.info.text)
                    let names = outdated.prefix(3).map(\.shortName).joined(separator: ", ")
                    Text(outdated.count > 3 ? String(localized: "\(names) and \(outdated.count - 3) more") : names)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Button("Pull Updates") {
                        Task {
                            for image in outdated {
                                model.pullReference = image.reference
                                await model.pull()
                                if let fresh = model.images.first(where: { $0.reference == image.reference }) {
                                    app.imageUpdates.pulled(fresh)
                                }
                            }
                        }
                    }
                    .disabled(model.isPulling)
                    .help("A newer image is published for these tags. Containers keep the old one until recreated.")
                }
                .panel()
                .frame(maxWidth: 300)
            }
        }
    }

    private func imageCard(_ row: ImageRow, _ model: ImagesViewModel) -> some View {
        let image = row.image
        let hasUpdate = app.imageUpdates.update(for: image)
        let (name, tag) = Self.split(image.shortName)
        return HoverReveal { hovering in VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                Text(String(name.split(separator: "/").last?.first ?? "?").uppercased())
                    .font(.title3.weight(.bold))
                    .foregroundStyle(image.isMachineImage ? Color.purple : DS.accent)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill((image.isMachineImage ? Color.purple : DS.accent).opacity(0.1)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(name).fontWeight(.semibold) + Text(tag.isEmpty ? "" : ":" + tag).foregroundStyle(.secondary))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Text([Format.bytes(row.size), usedText(row)].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text([row.source, image.architectures.sorted().joined(separator: ", "),
                          image.configuration.creationDate.map { Format.relative(fromISO: $0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Spacing.m) {
                if hasUpdate {
                    Button("Update available") {
                        model.pullReference = image.reference
                        Task {
                            await model.pull()
                            if let fresh = model.images.first(where: { $0.reference == image.reference }) {
                                app.imageUpdates.pulled(fresh)
                            }
                        }
                    }
                    .foregroundStyle(Tone.info.text)
                    .help("A newer image is published for this tag: pull it")
                    .disabled(model.isPulling)
                }
                Spacer(minLength: 0)
                if model.busy.contains(image.id) {
                    ProgressView().controlSize(.small)
                } else if hovering {
                    Button { app.requestRun(image: image.shortName) } label: { Image(systemName: "play.circle") }
                        .help("Run a container from this image")
                        .accessibilityLabel("Run image \(image.shortName)")
                    Button { pushTarget = PushTarget(reference: image.reference) } label: { Image(systemName: "arrow.up.circle") }
                        .help("Push")
                        .accessibilityLabel("Push image \(image.shortName)")
                    Button { pendingDelete = image } label: { Image(systemName: "trash") }
                        .help("Delete")
                        .accessibilityLabel("Delete image \(image.shortName)")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .frame(height: 18)
        }
        .panel(padding: DS.Spacing.m + DS.Spacing.xs) }
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel)
            .strokeBorder(hasUpdate ? Tone.info.fill.opacity(0.5) : .clear, lineWidth: 1))
        .contextMenu {
            Button("Run…") { app.requestRun(image: image.shortName) }
            Button("Push…") { pushTarget = PushTarget(reference: image.reference) }
            Divider()
            Button("Copy Reference") { copy(image.reference) }
            Button("Copy Digest") { copy(image.digest) }
            Divider()
            if selection.contains(image.id) && selection.count > 1 {
                Button("Delete \(selection.count) Images", role: .destructive) { askToDelete(model) }
            } else {
                Button("Delete", role: .destructive) { pendingDelete = image }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(image.shortName)
        .accessibilityIdentifier("images.row.\(image.shortName)")
    }

    /// "web" for one user, "3 containers", or "machine test1".
    private func usedText(_ row: ImageRow) -> String {
        if row.usedBy.isEmpty { return String(localized: "not used") }
        return row.usedBy.count == 1 ? row.usedBy[0] : String(localized: "\(row.usedBy.count) containers")
    }

    /// "nginx:alpine" → ("nginx", "alpine"); a digest reference keeps its name.
    static func split(_ reference: String) -> (String, String) {
        if let at = reference.firstIndex(of: "@") { return (String(reference[..<at]), "") }
        guard let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") else { return (reference, "") }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }

    private func shownPicker(_ model: ImagesViewModel) -> some View {
        let usage = model.usage
        let user = model.images.filter { showSystem || !$0.isSystem }
        let inUse = user.filter { !(usage[$0.reference] ?? []).isEmpty }.count
        return Picker("Show", selection: $shown) {
            Text("All \(user.count)").tag(Shown.all)
            Text("In use \(inUse)").tag(Shown.inUse)
            Text("Unused \(user.count - inUse)").tag(Shown.unused)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("images.shown")
    }

    @ToolbarContentBuilder
    private func toolbar(_ model: ImagesViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { shownPicker(model) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Show System Images", isOn: $showSystem)
                    .accessibilityIdentifier("images.showSystem")
                Button("Refresh") { Task { await model.load() } }
                    .accessibilityIdentifier("images.refresh")
                    .disabled(model.isLoading)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More")
            .menuIndicator(.hidden)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button(freeTitle(model)) { confirmPrune = true }
                .help("Remove unused or dangling images")
                .accessibilityIdentifier("images.prune")
            Button("Build…") { showBuild = true }
                .help("Build an image from a folder with a Dockerfile")
                .accessibilityIdentifier("images.build")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Pull Image…") { showPull = true }
                .buttonStyle(.borderedProminent)
                .help("Download an image")
                .accessibilityIdentifier("images.pull")
        }
    }

    /// "Free 8 GB…" when unused images take space, else "Clean Up…".
    private func freeTitle(_ model: ImagesViewModel) -> String {
        let size = model.unused.map(\.totalSize).reduce(0, +)
        return size > 0 ? String(localized: "Free \(Format.bytes(size))…", comment: "Button: free up disk space") : String(localized: "Clean Up…")
    }

    private func pruneMessage(_ model: ImagesViewModel) -> String {
        let unused = model.unused
        if unused.isEmpty {
            return String(localized: "Every image is used by a container. Untagged layers are leftovers from images that were rebuilt or pulled again.")
        }
        let names = unused.prefix(6).map(\.shortName).joined(separator: ", ")
        if unused.count > 6 {
            return String(localized: "Unused: \(names) and \(unused.count - 6) more. They can be pulled again later. Untagged layers are leftovers from images that were rebuilt or pulled again.")
        }
        return String(localized: "Unused: \(names). They can be pulled again later. Untagged layers are leftovers from images that were rebuilt or pulled again.")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A table row: an image plus who uses it, with sortable keys.
struct ImageRow: Identifiable {
    let image: ContainerImage
    let usedBy: [String]

    var id: String { image.id }
    var name: String { image.shortName }
    var size: Int { image.totalSize }
    var created: String { image.configuration.creationDate ?? "" }
    var useCount: Int { usedBy.count }

    /// "docker.io/library" → "Docker Hub", "ghcr.io/org" → itself.
    var source: String? {
        let parts = image.reference.split(separator: "/")
        guard parts.count > 1 else { return nil }
        let registry = String(parts[0])
        if registry == "docker.io" {
            return parts.count > 2 && parts[1] != "library" ? "Docker Hub · \(parts[1])" : "Docker Hub"
        }
        return parts.dropLast().joined(separator: "/")
    }
}

/// Identifiable wrapper so a push can be presented via `.sheet(item:)`.
struct PushTarget: Identifiable {
    let id = UUID()
    let reference: String
}

extension ContainerImage {
    /// A Linux image prepared for a machine (systemd added).
    var isMachineImage: Bool { reference.contains("irekobox-machine-") }
}
