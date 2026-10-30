import WidgetKit
import SwiftUI
import AppIntents
import ContainerKit

// Widgets and a Control Center control, from the snapshot the app writes
// into the shared app-group folder every half minute.

@main
struct IrekoboxWidgets: WidgetBundle {
    var body: some Widget {
        ProjectWidget()
        OverviewWidget()
        EngineControl()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var project: WidgetSnapshot.Project?
}

private let accent = Color(red: 0.04, green: 0.36, blue: 0.76)
private let green = Color(red: 0.10, green: 0.50, blue: 0.22)

// MARK: - Overview (medium)

struct OverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(engineRunning: true, running: 9, total: 11,
                                                             cpuHistory: [8, 12, 20, 18, 26, 22, 14, 18, 30, 23],
                                                             memoryBytes: 3_100_000_000, reclaimableBytes: 8_000_000_000))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())],
                            policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "overview", provider: OverviewProvider()) { entry in
            OverviewView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Irekobox")
        .description("What runs, and how busy it is.")
        .supportedFamilies([.systemMedium])
    }
}

struct OverviewView: View {
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Irekobox").font(.headline)
                    Spacer()
                    Text(snapshot.engineRunning ? "\(snapshot.running) running" : "Engine stopped")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.engineRunning ? green : .secondary)
                }
                Spark(values: snapshot.cpuHistory).stroke(accent, lineWidth: 2).frame(maxHeight: .infinity)
                HStack(spacing: 14) {
                    stat("\(Int((snapshot.cpuHistory.last ?? 0).rounded()))%", "CPU")
                    stat(ByteCountFormatter.string(fromByteCount: snapshot.memoryBytes, countStyle: .memory), "memory")
                    stat(ByteCountFormatter.string(fromByteCount: snapshot.reclaimableBytes, countStyle: .file), "to free")
                }
            }
            .widgetURL(URL(string: "irekobox://overview"))
        } else {
            Text("Open Irekobox once to see your containers here.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        (Text(verbatim: value).bold() + Text(verbatim: " ") + Text(label).foregroundStyle(.secondary)).font(.caption)
    }
}

/// A line through the values, scaled to their range.
struct Spark: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
        let top = max(10, values.max() ?? 0) * 1.2
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(value / top) * rect.height)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

// MARK: - A project (small, choose which)

struct ProjectChoice: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Compose Project"
    static let defaultQuery = ProjectChoiceQuery()
    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id)) }
}

struct ProjectChoiceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectChoice] {
        identifiers.map(ProjectChoice.init)
    }

    func suggestedEntities() async throws -> [ProjectChoice] {
        (WidgetSnapshot.load()?.projects ?? []).map { ProjectChoice(id: $0.name) }
    }
}

struct ProjectConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Compose Project"
    @Parameter(title: "Project") var project: ProjectChoice?
}

struct ProjectProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil,
                      project: WidgetSnapshot.Project(name: "shop", running: 3, total: 3, healthy: true, port: 8080))
    }

    func snapshot(for configuration: ProjectConfiguration, in context: Context) async -> SnapshotEntry {
        context.isPreview ? placeholder(in: context) : entry(configuration)
    }

    func timeline(for configuration: ProjectConfiguration, in context: Context) async -> Timeline<SnapshotEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(_ configuration: ProjectConfiguration) -> SnapshotEntry {
        let snapshot = WidgetSnapshot.load()
        let projects = snapshot?.projects ?? []
        let chosen = projects.first { $0.name == configuration.project?.id } ?? projects.first
        return SnapshotEntry(date: Date(), snapshot: snapshot, project: chosen)
    }
}

struct ProjectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "project", intent: ProjectConfiguration.self, provider: ProjectProvider()) { entry in
            ProjectView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Compose Project")
        .description("How many of its services run, and where to open it.")
        .supportedFamilies([.systemSmall])
    }
}

struct ProjectView: View {
    let entry: SnapshotEntry

    var body: some View {
        if let project = entry.project {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(project.running)/\(project.total)").font(.system(size: 40, weight: .bold)).monospacedDigit()
                Spacer()
                Text(status(project)).font(.caption).foregroundStyle(project.running == 0 ? .secondary : project.healthy ? green : .orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: "irekobox://project/\(project.name)"))
        } else {
            Text("No compose projects yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func status(_ project: WidgetSnapshot.Project) -> String {
        if project.running == 0 { return String(localized: "Stopped") }
        var text = project.healthy ? String(localized: "All healthy") : String(localized: "Needs attention")
        if let port = project.port { text += " · :\(String(port))" }
        return text
    }
}

// MARK: - Control Center

struct OpenIrekobox: AppIntent {
    static let title: LocalizedStringResource = "Open Irekobox"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct EngineControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "engine") {
            let snapshot = WidgetSnapshot.load()
            ControlWidgetButton(action: OpenIrekobox()) {
                Label {
                    Text("Engine")
                    Text(snapshot.map { $0.engineRunning ? String(localized: "On · \($0.running) running") : String(localized: "Off") }
                         ?? String(localized: "Open the app"))
                } icon: {
                    Image(systemName: "power")
                }
            }
        }
        .displayName("Irekobox Engine")
        .description("Whether the engine runs and how many containers; opens Irekobox.")
    }
}
