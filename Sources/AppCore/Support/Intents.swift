import AppIntents
import ContainerKit

/// Irekobox's App Intents, discovered by the app through this package.
public struct AppCoreIntents: AppIntentsPackage {}

// MARK: - Entities

/// A compose project, for Shortcuts and Spotlight.
public struct ProjectEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Compose Project"
    public static let defaultQuery = ProjectQuery()

    public let id: String
    let running: Int
    let total: Int

    public var displayRepresentation: DisplayRepresentation {
        // The title is the project's name (data).
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id), subtitle: "\(running) of \(total) running",
                              image: .init(systemName: "square.stack.3d.up"))
    }
}

public struct ProjectQuery: EntityStringQuery {
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    private func all() -> [ProjectEntity] {
        ContainerList.group(app.model.containers.filter { !$0.isSystem }).compactMap { group in
            group.project.map { ProjectEntity(id: $0, running: group.running, total: group.containers.count) }
        }
    }

    public func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    public func entities(matching string: String) async throws -> [ProjectEntity] {
        await all().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }

    public func suggestedEntities() async throws -> [ProjectEntity] { await all() }
}

/// A container, for Shortcuts and Spotlight.
public struct ContainerEntity: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Container"
    public static let defaultQuery = ContainerQuery()

    public let id: String
    let image: String
    let running: Bool

    public var displayRepresentation: DisplayRepresentation {
        // The title is the container's name (data).
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id),
                              subtitle: running ? "Running · \(image)" : "Stopped · \(image)",
                              image: .init(systemName: "shippingbox"))
    }
}

public struct ContainerQuery: EntityStringQuery {
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    private func all() -> [ContainerEntity] {
        app.model.containers.filter { !$0.isSystem }.map {
            ContainerEntity(id: $0.id, image: $0.imageShortName, running: $0.state.isRunning)
        }
    }

    public func entities(for identifiers: [String]) async throws -> [ContainerEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    public func entities(matching string: String) async throws -> [ContainerEntity] {
        await all().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }

    public func suggestedEntities() async throws -> [ContainerEntity] { await all() }
}

// MARK: - Projects

public struct StartProjectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Compose Project"
    public static let description = IntentDescription("Starts every service of a compose project.")

    @Parameter(title: "Project") public var project: ProjectEntity
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let containers = app.model.containers.filter { ContainerList.project(of: $0) == project.id && !$0.state.isRunning }
        guard !app.model.containers.filter({ ContainerList.project(of: $0) == project.id }).isEmpty else {
            throw IntentFailure(String(localized: "\(project.id) has no containers yet; start it once in Irekobox."))
        }
        app.noteHandAction(stopped: false, containers.map(\.id))
        for container in containers { try await app.engine.startContainer(container.id) }
        await app.model.refresh([.containers])
        return .result(dialog: "Started \(project.id).")
    }
}

public struct StopProjectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop Compose Project"
    public static let description = IntentDescription("Stops every service of a compose project.")

    @Parameter(title: "Project") public var project: ProjectEntity
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let containers = app.model.containers.filter { ContainerList.project(of: $0) == project.id && $0.state.isRunning }
        app.noteHandAction(stopped: true, containers.map(\.id))
        for container in containers { try await app.engine.stopContainer(container.id) }
        await app.model.refresh([.containers])
        return .result(dialog: "Stopped \(project.id).")
    }
}

public struct OpenProjectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Compose Project"
    public static let openAppWhenRun = true

    @Parameter(title: "Project") public var project: ProjectEntity
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        app.section = .compose
        app.revealProject = project.id
        app.mainWindowRequest += 1
        return .result()
    }
}

// MARK: - Containers

public struct RestartContainerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Restart Container"

    @Parameter(title: "Container") public var container: ContainerEntity
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        app.noteHandAction(stopped: true, [container.id])
        if container.running { try await app.engine.stopContainer(container.id) }
        try await app.engine.startContainer(container.id)
        app.noteHandAction(stopped: false, [container.id])
        await app.model.refresh([.containers])
        return .result(dialog: "Restarted \(container.id).")
    }
}

public struct ShowLogsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Container Logs"
    public static let openAppWhenRun = true

    @Parameter(title: "Container") public var container: ContainerEntity
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        app.openContainer(container.id, tab: .logs)
        app.mainWindowRequest += 1
        return .result()
    }
}

public struct RunImageIntent: AppIntent {
    public static let title: LocalizedStringResource = "Run Container"
    public static let description = IntentDescription("Opens Run Container with the image filled in.")
    public static let openAppWhenRun = true

    @Parameter(title: "Image", inputOptions: .init(keyboardType: .default)) public var image: String
    @Dependency private var app: AppState

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        app.requestRun(image: image)
        app.mainWindowRequest += 1
        return .result()
    }
}

struct IntentFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
