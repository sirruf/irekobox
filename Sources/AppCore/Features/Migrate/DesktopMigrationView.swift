import SwiftUI
import MigrationKit

/// Move a Docker Desktop setup: a report of what moves (as is, with
/// changes, or not at all), then the move itself with per-item progress.
struct DesktopMigrationView: View {
    @Environment(AppState.self) private var app
    @State private var model = DesktopMigrationModel()

    var body: some View {
        Group {
            switch model.phase {
            case .checking, .scanning:
                ProgressView(model.phase == .checking ? "Looking for Docker Desktop…" : "Reading Docker Desktop…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .blocked(let blocker):
                blocked(blocker)
            case .ready, .moving, .finished:
                report
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.check(app: app) }
        .accessibilityIdentifier("migrate.desktop")
    }

    // MARK: - Before

    @ViewBuilder
    private func blocked(_ blocker: DesktopMigrationModel.Blocker) -> some View {
        switch blocker {
        case .noDocker:
            ContentUnavailableView("Docker CLI not found", systemImage: "shippingbox",
                                   description: Text("Moving needs Docker Desktop installed, with its docker command."))
        case .desktopNotRunning:
            DockerDesktopStopped { Task { await model.check(app: app) } }
        case .socketOff:
            ContentUnavailableView {
                Label("Turn on the Docker API", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Containers are recreated through Irekobox's Docker API, from Docker's own settings.")
            } actions: {
                Button("Turn On") {
                    app.setDockerSocketEnabled(true)
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await model.check(app: app)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!app.backgroundAgentEnabled)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't read Docker Desktop", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.check(app: app) } }
            }
        }
    }

    // MARK: - Report

    private var report: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    summary.panel()
                    ForEach(DesktopMigrationModel.order, id: \.self) { kind in
                        let rows = model.items(of: kind)
                        if !rows.isEmpty {
                            MigrateGroup(title: Self.title(kind),
                                         note: kind == .registry ? "Passwords stay in Docker's keychain entry; sign in again in Settings › Registries." : nil) {
                                ForEach(rows) { row($0) }
                            }
                        }
                    }
                }
                .padding(DS.Spacing.l)
            }
            Divider()
            footer
        }
    }

    private var summary: some View {
        let counts = model.counts
        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(verbatim: "Docker Desktop \(model.sourceVersion)").font(.headline)
            HStack(spacing: DS.Spacing.m) {
                tile("Move as they are", counts.moves, .positive, "checkmark.circle.fill")
                tile("Move with small changes", counts.changes, .warning, "exclamationmark.circle.fill")
                tile("Can't move", counts.blocked, counts.blocked > 0 ? .critical : .neutral, "xmark.circle.fill")
            }
            Text("Nothing in Docker Desktop is removed, so you can switch back at any time. Chosen containers bring their images, volumes and networks along.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func tile(_ title: LocalizedStringKey, _ count: Int, _ tone: Tone, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(tone.text)
            Text(count, format: .number).font(.largeTitle.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(tone.fill.opacity(0.08)))
        .hairline(RoundedRectangle(cornerRadius: DS.Radius.card), tone.fill.opacity(0.3))
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: DesktopMigration.Item) -> some View {
        let planned = model.plannedIDs.contains(item.id)
        let chosen = model.selected.contains(item.id)
        return HStack(alignment: .top, spacing: DS.Spacing.s) {
            if item.kind == .registry {
                Image(systemName: "key").frame(width: 18).foregroundStyle(.secondary)
            } else {
                Toggle(isOn: Binding(get: { planned }, set: { _ in model.toggle(item) })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!item.movable || model.phase == .moving || (planned && !chosen))
                    .help(planned && !chosen ? "Needed by a chosen item" : "")
                    .accessibilityLabel("Move \(item.name)")
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(item.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if planned && !chosen { Text("needed").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(item.detail + (item.size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(item.problems, id: \.self) { problem in
                    Label(problem.text, systemImage: problem.level == .blocked ? "xmark.octagon" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(problem.level == .blocked ? Tone.critical.text : Tone.warning.text)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            status(item)
        }
        .padding(.vertical, DS.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func status(_ item: DesktopMigration.Item) -> some View {
        switch model.statuses[item.id] {
        case .running: ProgressView().controlSize(.small)
        case .done: Label("Moved", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.positive.text).font(.caption)
        case .failed(let message):
            Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(Tone.critical.text).font(.caption)
                .help(message)
        case .skipped(let reason):
            Text("Skipped").font(.caption).foregroundStyle(.secondary).help(reason)
        case .pending, nil: EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.m) {
            switch model.phase {
            case .moving:
                ProgressView().controlSize(.small)
                Text("Moving… \(model.doneCount) of \(model.plannedIDs.count) done").foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.cancel() }
            case .finished:
                let failed = model.statuses.values.filter { if case .failed = $0 { true } else { false } }.count
                Label(failed == 0 ? "Done. \(model.doneCount) items moved." : "\(failed) failed — hover a row for why; Move again continues.",
                      systemImage: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(failed == 0 ? Tone.positive.text : Tone.warning.text)
                Spacer()
                Button("Start Over") { Task { await model.startOver() } }
                moveButton
            default:
                Toggle("Start containers that were running", isOn: $model.startRunning)
                Toggle("Stop them in Docker Desktop first", isOn: $model.stopSource)
                    .disabled(!model.startRunning)
                    .help("Frees their ports; Docker Desktop keeps them, stopped.")
                Spacer()
                if model.hasSavedProgress {
                    Button("Start Over") { Task { await model.startOver() } }
                }
                moveButton
            }
        }
        .padding(DS.Spacing.m)
        .background(.bar)
    }

    private var moveButton: some View {
        let count = model.plannedIDs.count
        let size = model.plannedSize
        let title = count == 0 ? String(localized: "Move")
            : size > 0 ? String(localized: "Move \(count) Items (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
            : String(localized: "Move \(count) Items")
        return Button(title) {
            model.move()
        }
        .buttonStyle(.borderedProminent)
        .disabled(count == 0)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("migrate.desktop.move")
    }

    static func title(_ kind: DesktopMigration.Kind) -> String {
        switch kind {
        case .container: return String(localized: "Containers")
        case .image: return String(localized: "Images")
        case .volume: return String(localized: "Volumes")
        case .network: return String(localized: "Networks")
        case .registry: return String(localized: "Registry sign-ins")
        }
    }
}
