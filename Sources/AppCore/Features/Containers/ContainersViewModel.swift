import Foundation
import Observation
import ContainerKit

@MainActor
@Observable
final class ContainersViewModel {
    private let engine: any ContainerEngine
    private let model: EngineModel

    /// Error from the last action or explicit load.
    var error: String?
    /// IDs with an in-flight action, to disable their controls.
    var busyIDs: Set<String> = []

    var containers: [Container] { model.containers }
    var isLoading: Bool { model.isLoading(.containers) }

    /// Reports stops and starts by the user to the supervisor.
    private let handAction: (_ stopped: Bool, _ ids: [String]) -> Void

    init(engine: any ContainerEngine, model: EngineModel,
         handAction: @escaping (_ stopped: Bool, _ ids: [String]) -> Void = { _, _ in }) {
        self.engine = engine
        self.model = model
        self.handAction = handAction
    }

    func load() async {
        await model.refresh([.containers])
        error = model.errorMessage(.containers)
    }

    func start(_ container: Container) async { await start([container.id]) }
    func stop(_ container: Container) async { await stop([container.id]) }
    func delete(_ container: Container) async { await delete([container.id]) }

    func start(_ ids: Set<String>) async {
        handAction(false, Array(ids))
        await act(ids) { try await self.engine.startContainer($0) }
    }
    func stop(_ ids: Set<String>) async {
        handAction(true, Array(ids))
        await act(ids) { try await self.engine.stopContainer($0) }
    }
    func delete(_ ids: Set<String>) async { await act(ids) { try await self.engine.deleteContainer($0, force: true) } }

    /// Stop, then start again (`container` has no restart verb).
    func restart(_ ids: Set<String>) async {
        handAction(true, Array(ids))
        defer { handAction(false, Array(ids)) }
        await act(ids) { id in
            try await self.engine.stopContainer(id)
            try await self.engine.startContainer(id)
        }
    }

    /// Run `body` for each id concurrently, then refresh the shared list once.
    /// Failures are collected into one message naming the containers.
    private func act(_ ids: Set<String>, _ body: @escaping @Sendable (String) async throws -> Void) async {
        guard !ids.isEmpty else { return }
        busyIDs.formUnion(ids)
        defer { busyIDs.subtract(ids) }
        let failures = await withTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    do { try await body(id); return (id, nil) }
                    catch { return (id, error.localizedDescription) }
                }
            }
            var failed: [(String, String)] = []
            for await (id, message) in group { if let message { failed.append((id, message)) } }
            return failed
        }
        if !failures.isEmpty {
            error = failures.count == 1
                ? failures[0].1
                : String(localized: "\(failures.count) containers failed: \(failures.map { "\($0.0) (\($0.1))" }.joined(separator: "; "))")
        }
        await model.refresh([.containers])
    }
}
