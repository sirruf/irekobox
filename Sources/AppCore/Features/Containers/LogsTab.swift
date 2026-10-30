import SwiftUI
import UniformTypeIdentifiers

/// Logs tab: follows the container's output with search, a severity filter,
/// timestamps, wrapping, and pause-on-scroll. With `sources`, follows several
/// containers at once (a compose project), each line prefixed by its label.
struct LogsTab: View {
    @Environment(AppState.self) private var app
    let id: String
    var sources: [(label: String, id: String)]? = nil
    /// Any other line stream (kubectl logs), started afresh on reconnect.
    var lines: (() -> AsyncThrowingStream<String, Error>)? = nil
    /// Offers to open the same logs in their own window.
    var window: LogsTarget? = nil

    @State private var model = LogViewerModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            LogTextView(model: model) { id in app.openContainer(id, tab: .logs) }
                .overlay {
                    if model.buffer.entries.isEmpty && model.streamError == nil {
                        ContentUnavailableView("No Output Yet", systemImage: "text.alignleft",
                                               description: Text("New lines appear here as the container writes them."))
                            .accessibilityIdentifier("logs.empty")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !model.isFollowing {
                        Button {
                            model.isFollowing = true
                        } label: {
                            Label(model.unseen > 0 ? "\(model.unseen) new lines — Resume"
                                                   : "Resume following",
                                  systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(DS.Spacing.l)
                        .accessibilityIdentifier("logs.resume")
                    }
                }
                .overlay(alignment: .bottom) {
                    if let error = model.streamError {
                        NoticeBanner(tone: .critical, title: "Log stream ended", message: error) {
                            Button("Reconnect") { reconnect() }
                        }
                        .padding(DS.Spacing.l)
                    }
                }
        }
        .onChange(of: related, initial: true) { _, states in
            model.follow(followed)
            model.observe(states)
        }
        .task(id: "\(streamKey) \(sources?.map(\.id).joined(separator: ",") ?? id)") {
            if let lines {
                await model.stream(lines: lines())
            } else if let sources {
                await model.stream(engine: app.engine, sources: sources)
            } else {
                await model.stream(engine: app.engine, id: id)
            }
        }
    }

    /// Containers whose output is shown (none for other line streams).
    private var followed: Set<String> {
        lines != nil ? [] : Set(sources?.map(\.id) ?? [id])
    }

    /// The followed containers and the others in their projects, as they are
    /// now: their stops, starts and health changes annotate the log.
    private var related: [String: LogContext.State] {
        let followed = followed
        guard !followed.isEmpty else { return [:] }
        let containers = app.model.containers
        let projects = Set(containers.filter { followed.contains($0.id) }.compactMap(ContainerList.project(of:)))
        var states: [String: LogContext.State] = [:]
        for container in containers where followed.contains(container.id)
            || ContainerList.project(of: container).map(projects.contains) == true {
            states[container.id] = LogContext.State(name: container.serviceName, running: container.state.isRunning,
                                                    health: app.health[container.id], started: container.startedDate)
        }
        return states
    }

    /// Restarting the task (e.g. after an error) reconnects the stream.
    @State private var streamKey = 0
    private func reconnect() { streamKey &+= 1 }

    private var toolbar: some View {
        @Bindable var model = model
        return HStack(spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search logs", text: $model.filter.query)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 140, maxWidth: 260)
                    .accessibilityIdentifier("logs.search")
                if !model.filter.query.isEmpty {
                    Text("\(model.matchCount) matches")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.subtleFill))

            Picker("Level", selection: $model.filter.warningsOnly) {
                Text("All").tag(false)
                Text(model.problemCount > 0 ? "Warnings & errors \(model.problemCount)" : "Warnings & errors").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .accessibilityIdentifier("logs.level")

            Toggle("Timestamps", isOn: $model.showTimestamps).toggleStyle(.checkbox)
            Toggle("Wrap", isOn: $model.wrapLines).toggleStyle(.checkbox)

            Spacer()

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.visibleText(), forType: .string)
            }
            .help("Copy the visible lines")
            Button("Export…") { export() }
            Button("Clear") { model.clear() }
                .help("Clear this view (the container's log is kept)")
            if let window { OpenLogsWindowButton(target: window) }
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(id).log"
        panel.allowedContentTypes = [.log, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.visibleText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            app.actionError = String(localized: "Couldn't export logs: \(error.localizedDescription)")
        }
    }
}
