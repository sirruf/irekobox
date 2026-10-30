import SwiftUI
import ContainerKit

/// ⌘K: find any container, image, section or action and act on it from the
/// keyboard (↑/↓ to choose, Return to run, Esc to close).
struct PaletteView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = PaletteSearch.rank(items + verbs(query), query: query)
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Containers, images, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .accessibilityIdentifier("palette.search")
                    .onSubmit { run(results) }
            }
            .padding(DS.Spacing.l)
            Divider()
            if results.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding(DS.Spacing.xl)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Plain VStack: at most 30 rows, and a lazy stack kept
                        // stale rows on screen while the results reordered.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sections(results), id: \.kind) { section in
                                Text(section.kind.title)
                                    .textCase(.uppercase)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, DS.Spacing.m)
                                    .padding(.top, section.offset == 0 ? DS.Spacing.xs : DS.Spacing.m)
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { position, item in
                                    let index = section.offset + position
                                    row(item, isSelected: index == selected)
                                        .onTapGesture {
                                            selected = index
                                            run(results)
                                        }
                                }
                            }
                        }
                        .padding(DS.Spacing.s)
                    }
                    .onChange(of: selected) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
            Divider()
            HStack(spacing: DS.Spacing.m) {
                Text("↑↓ move")
                Text("↩ do it")
                Text("esc close")
                Spacer()
                Text("Try: “logs db”, “open 8080”, “run postgres”")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(.bar)
        }
        .frame(width: 620, height: 420)
        .onAppear {
            query = app.paletteQuery
            app.paletteQuery = ""
            focused = true
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(0, results.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(selected - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        // `.contain` keeps the ids of the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette")
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(isSelected ? .white : DS.accent)
            Text(item.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary).lineLimit(1)
            }
            Spacer()
            if isSelected {
                Text(verbatim: "↩").foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(isSelected ? DS.accent : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Consecutive runs of one kind, with the index of their first item.
    private func sections(_ results: [PaletteItem]) -> [(kind: PaletteItem.Kind, offset: Int, items: [PaletteItem])] {
        var sections: [(kind: PaletteItem.Kind, offset: Int, items: [PaletteItem])] = []
        for (index, item) in results.enumerated() {
            if sections.last?.kind == item.kind {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((item.kind, index, [item]))
            }
        }
        return sections
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selected) else { return }
        let item = results[selected]
        dismiss()
        item.perform()
    }

    // MARK: - Items

    /// Verb first, once something is typed: "logs db", "restart api",
    /// "open 8080", "run postgres".
    private func verbs(_ query: String) -> [PaletteItem] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        var items: [PaletteItem] = []
        for container in app.model.containers where !container.isSystem {
            let id = container.id
            items.append(PaletteItem(id: "logs-\(id)", kind: .action, title: String(localized: "Logs \(id)"), subtitle: String(localized: "its output"),
                                     systemImage: "text.alignleft", keywords: "logs \(id)",
                                     perform: { [app] in app.openContainer(id, tab: .logs) }))
            if container.state.isRunning {
                items.append(PaletteItem(id: "restart-\(id)", kind: .action, title: String(localized: "Restart \(id)"),
                                         subtitle: ContainerList.project(of: container) ?? "",
                                         systemImage: "arrow.clockwise", keywords: "restart \(id)",
                                         perform: { [app] in
                                             Task {
                                                 await app.perform {
                                                     app.noteHandAction(stopped: true, [id])
                                                     try await app.engine.stopContainer(id)
                                                     try await app.engine.startContainer(id)
                                                     app.noteHandAction(stopped: false, [id])
                                                 }
                                             }
                                         }))
                for port in ContainerPresentation(container).ports {
                    guard let url = port.url else { continue }
                    items.append(PaletteItem(id: "open-\(id)-\(port.id)", kind: .action,
                                             title: String(localized: "Open \(url.host() ?? "localhost"):\(String(port.hostPort))"),
                                             subtitle: id, systemImage: "safari",
                                             keywords: "open \(String(port.hostPort))",
                                             perform: { NSWorkspace.shared.open(url) }))
                }
            }
        }
        let lowered = typed.lowercased()
        if lowered.hasPrefix("run "), case let image = String(typed.dropFirst(4)).trimmingCharacters(in: .whitespaces), !image.isEmpty {
            items.append(PaletteItem(id: "run-typed", kind: .action, title: String(localized: "Run \(image)…"),
                                     subtitle: String(localized: "Run Container, filled in"), systemImage: "play",
                                     keywords: "run \(image)",
                                     perform: { [app] in app.requestRun(image: image) }))
        }
        return items
    }

    private var items: [PaletteItem] {
        var items: [PaletteItem] = []
        for container in app.model.containers where !container.isSystem {
            let presentation = ContainerPresentation(container)
            let ports = presentation.ports.map(\.label).joined(separator: " ")
            items.append(PaletteItem(
                id: "container-\(container.id)", kind: .container, title: container.id,
                subtitle: [presentation.label, container.imageShortName, ports].filter { !$0.isEmpty }.joined(separator: " · "),
                systemImage: "shippingbox",
                keywords: [container.configuration.image.reference, ContainerList.project(of: container) ?? "", ports].joined(separator: " "),
                perform: { [app] in
                    app.section = .containers
                    app.revealContainer = container.id
                }))
        }
        for image in app.model.images where !image.isSystem {
            items.append(PaletteItem(
                id: "image-\(image.id)", kind: .image, title: image.shortName,
                subtitle: String(localized: "\(Format.bytes(image.totalSize)) · run a container from it"),
                systemImage: "photo.stack", keywords: image.reference,
                perform: { [app] in app.requestRun(image: image.shortName) }))
        }
        for section in SidebarSection.allCases {
            items.append(PaletteItem(
                id: "section-\(section.rawValue)", kind: .section, title: section.title,
                subtitle: section.shortcut.map { "⌘\($0)" } ?? "",
                systemImage: section.systemImage, keywords: section.rawValue,
                perform: { [app] in app.section = section }))
        }
        items.append(PaletteItem(id: "action-run", kind: .action, title: String(localized: "Run Container…"), subtitle: "⌘N",
                                 systemImage: "play", keywords: "new container start",
                                 perform: { [app] in app.requestRun() }))
        items.append(PaletteItem(id: "action-refresh", kind: .action, title: String(localized: "Refresh"), subtitle: "⌘R",
                                 systemImage: "arrow.clockwise", keywords: "reload",
                                 perform: { [app] in app.requestRefresh() }))
        items.append(PaletteItem(id: "action-settings", kind: .action, title: String(localized: "Settings…"), subtitle: "⌘,",
                                 systemImage: "gearshape", keywords: "preferences engine registries",
                                 perform: { [openSettings] in openSettings() }))
        items.append(PaletteItem(id: "action-stop-engine", kind: .action, title: String(localized: "Stop Engine"),
                                 systemImage: "stop.circle", keywords: "services system",
                                 perform: { [app] in app.engineRequest = .stop }))
        return items
    }
}
