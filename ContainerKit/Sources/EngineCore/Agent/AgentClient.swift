import Foundation
import os
import ContainerKit

/// ``EngineStateSource`` backed by the background agent over XPC.
///
/// Interests are tracked locally so they can be re-registered after the agent
/// restarts (launchd relaunches it); updates pushed by the agent are fanned out
/// to ``updates()`` subscribers.
public final class AgentClient: NSObject, EngineStateSource, AgentClientProtocol, @unchecked Sendable {
    public enum ClientError: Error, Equatable {
        case unreachable(String)
        case timedOut
        case incompatible(agentProtocol: Int)
    }

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var configuration: AgentConfiguration?
    private var latest = EngineUpdate(snapshot: EngineSnapshot(), events: [])
    private var subscribers: [UUID: AsyncStream<EngineUpdate>.Continuation] = [:]
    /// Local interest id → resources and the agent's token for them.
    private var interests: [UUID: (resources: Set<EngineResource>, remote: String?)] = [:]
    private var visible = false

    /// Called when the agent connection is lost for good (invalidated).
    public var onDisconnect: (@Sendable () -> Void)?

    /// Connect to the installed agent; it must be signed by the same team.
    public convenience init(machServiceName: String = AgentConstants.machServiceName) {
        self.init {
            let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
            connection.setCodeSigningRequirement(AgentConstants.clientRequirement)
            return connection
        }
    }

    /// Connect through an endpoint (tests use an anonymous listener).
    convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    private init(makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.makeConnection = makeConnection
    }

    deinit {
        connection?.invalidate()
    }

    // MARK: - Connecting

    /// Say hello, push `configuration`, and subscribe to updates.
    @discardableResult
    public func connect(configuration: AgentConfiguration, timeout: Duration = .seconds(3)) async throws -> AgentInfo {
        let connection = makeConnection()
        connection.remoteObjectInterface = .agentService
        connection.exportedInterface = .agentClient
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in self?.agentInterrupted() }
        connection.invalidationHandler = { [weak self] in self?.agentInvalidated() }
        connection.resume()
        lock.withLock {
            self.connection?.invalidate()
            self.connection = connection
            self.configuration = configuration
        }
        let info = try await hello(timeout: timeout)
        guard info.protocolVersion == AgentConstants.protocolVersion else {
            throw ClientError.incompatible(agentProtocol: info.protocolVersion)
        }
        try await establish(timeout: timeout)
        return info
    }

    public func hello(timeout: Duration = .seconds(3)) async throws -> AgentInfo {
        let data: Data = try await call(timeout: timeout) { proxy, reply in proxy.hello(reply: reply) }
        guard let info = AgentJSON.decode(AgentInfo.self, data) else { throw ClientError.unreachable("bad hello") }
        return info
    }

    /// Tell the agent containers were stopped or started by the user.
    public func handAction(stopped: Bool, names: [String]) {
        let payload = AgentJSON.encode(names)
        proxy()?.handAction(stopped: stopped, names: payload)
    }

    /// Alerts newer than `sequence`, and the newest sequence.
    public func alerts(after sequence: UInt64, timeout: Duration = .seconds(3)) async throws -> ([ContainerAlert], UInt64) {
        let (data, latest): (Data, UInt64) = try await call(timeout: timeout) { proxy, reply in
            proxy.alerts(after: sequence) { data, latest in reply((data, latest)) }
        }
        return (AgentJSON.decode([ContainerAlert].self, data) ?? [], latest)
    }

    /// Container name → health status ("starting", "healthy", "unhealthy").
    public func healthStatuses(timeout: Duration = .seconds(3)) async throws -> [String: String] {
        let data: Data = try await call(timeout: timeout) { proxy, reply in proxy.healthStatuses(reply: reply) }
        return AgentJSON.decode([String: String].self, data) ?? [:]
    }

    /// The agent's Docker API socket.
    public func dockerStatus(timeout: Duration = .seconds(3)) async throws -> DockerSocketStatus {
        let data: Data = try await call(timeout: timeout) { proxy, reply in proxy.dockerStatus(reply: reply) }
        guard let status = AgentJSON.decode(DockerSocketStatus.self, data) else { throw ClientError.unreachable("bad docker status") }
        return status
    }

    /// Push changed settings (binary path, polling interval) to the agent.
    public func updateConfiguration(_ configuration: AgentConfiguration) async {
        lock.withLock { self.configuration = configuration }
        let payload = AgentJSON.encode(configuration)
        let _: Void? = try? await call(timeout: .seconds(5)) { proxy, reply in
            proxy.configure(payload) { reply(()) }
        }
    }

    /// Close the connection; the agent drops this client's interests. Needed
    /// because the connection retains the client (it is the exported object).
    public func disconnect() {
        let connection = lock.withLock { () -> NSXPCConnection? in
            defer { self.connection = nil }
            return self.connection
        }
        connection?.invalidate()
    }

    /// Ask the agent to exit; launchd relaunches it from the current binary.
    public func restartAgent() {
        proxy()?.restart()
    }

    /// Configure, subscribe, and (re)register interests and visibility.
    private func establish(timeout: Duration) async throws {
        if let configuration = lock.withLock({ self.configuration }) {
            let payload = AgentJSON.encode(configuration)
            let _: Void = try await call(timeout: timeout) { proxy, reply in
                proxy.configure(payload) { reply(()) }
            }
        }
        let data: Data = try await call(timeout: timeout) { proxy, reply in proxy.subscribe(reply: reply) }
        if let update = AgentJSON.decode(EngineUpdate.self, data) { deliver(update) }

        let pending = lock.withLock { interests.map { ($0.key, $0.value.resources) } }
        for (id, resources) in pending {
            let token = try await remoteInterest(resources, timeout: timeout)
            lock.withLock { interests[id]?.remote = token }
        }
        let isVisible = lock.withLock { visible }
        proxy()?.setVisible(isVisible)
    }

    private static let log = Logger(subsystem: "com.irekobox.app", category: "agent-client")

    private func agentInterrupted() {
        // The agent died and launchd will relaunch it: resubscribe when it's back.
        Self.log.info("agent connection interrupted; reconnecting")
        Task {
            for attempt in 1...20 {
                try? await Task.sleep(for: .milliseconds(500 * attempt))
                if (try? await establish(timeout: .seconds(3))) != nil {
                    let pid = (try? await hello())?.pid ?? 0
                    Self.log.info("agent re-established (pid \(pid))")
                    return
                }
            }
            agentInvalidated()
        }
    }

    private func agentInvalidated() {
        Self.log.info("agent connection invalidated")
        lock.withLock { connection = nil }
        onDisconnect?()
    }

    // MARK: - EngineStateSource

    public func updates() async -> AsyncStream<EngineUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<EngineUpdate>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let current = lock.withLock { () -> EngineUpdate in
            subscribers[id] = continuation
            return latest
        }
        continuation.yield(EngineUpdate(snapshot: current.snapshot, events: []))
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func addInterest(_ resources: Set<EngineResource>) async -> UUID {
        let id = UUID()
        lock.withLock { interests[id] = (resources, nil) }
        if let token = try? await remoteInterest(resources, timeout: .seconds(3)) {
            let stillWanted = lock.withLock { () -> Bool in
                guard interests[id] != nil else { return false }
                interests[id]?.remote = token
                return true
            }
            if !stillWanted { proxy()?.removeInterest(token) }
        }
        return id
    }

    public func removeInterest(_ token: UUID) async {
        let remote = lock.withLock { interests.removeValue(forKey: token)?.remote }
        if let remote { proxy()?.removeInterest(remote) }
    }

    public func refreshSnapshot(_ resources: Set<EngineResource>) async -> EngineSnapshot {
        let payload = AgentJSON.encode(Array(resources))
        let data: Data? = try? await call(timeout: .seconds(60)) { proxy, reply in
            proxy.refresh(payload, reply: reply)
        }
        if let data, let snapshot = AgentJSON.decode(EngineSnapshot.self, data) {
            return snapshot
        }
        return lock.withLock { latest.snapshot }
    }

    public func setVisible(_ visible: Bool) async {
        lock.withLock { self.visible = visible }
        proxy()?.setVisible(visible)
    }

    public func currentlyPolled() async -> Set<EngineResource> {
        let data: Data? = try? await call(timeout: .seconds(3)) { proxy, reply in proxy.polledResources(reply: reply) }
        return Set(data.flatMap { AgentJSON.decode([EngineResource].self, $0) } ?? [])
    }

    // MARK: - AgentClientProtocol

    public func receive(update: Data) {
        guard let update = AgentJSON.decode(EngineUpdate.self, update) else { return }
        deliver(update)
    }

    private func deliver(_ update: EngineUpdate) {
        let continuations = lock.withLock { () -> [AsyncStream<EngineUpdate>.Continuation] in
            latest = update
            return Array(subscribers.values)
        }
        for continuation in continuations { continuation.yield(update) }
    }

    // MARK: - Calls

    private func remoteInterest(_ resources: Set<EngineResource>, timeout: Duration) async throws -> String {
        let payload = AgentJSON.encode(Array(resources))
        return try await call(timeout: timeout) { proxy, reply in proxy.addInterest(payload, reply: reply) }
    }

    private func proxy(errorHandler: @escaping @Sendable (Error) -> Void = { _ in }) -> AgentServiceProtocol? {
        lock.withLock { connection }?.remoteObjectProxyWithErrorHandler(errorHandler) as? AgentServiceProtocol
    }

    /// One request/reply round trip that resolves exactly once: reply, XPC
    /// error, or timeout.
    private func call<T: Sendable>(timeout: Duration,
                                   _ body: @escaping (AgentServiceProtocol, @escaping @Sendable (T) -> Void) -> Void)
        async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.install(continuation)
            guard let proxy = proxy(errorHandler: { once.resume(.failure(ClientError.unreachable($0.localizedDescription))) }) else {
                once.resume(.failure(ClientError.unreachable("not connected")))
                return
            }
            body(proxy) { once.resume(.success($0)) }
            once.expire(after: timeout, with: ClientError.timedOut)
        }
    }
}

/// Resumes a continuation once; later results are dropped. A deadline set
/// with ``expire(after:with:)`` is cancelled by the first result, so no
/// timer stays scheduled after a reply.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var deadline: DispatchWorkItem?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Fail with `error` after `timeout` unless a result came first.
    func expire(after timeout: Duration, with error: Error) {
        let item = DispatchWorkItem { [weak self] in self?.resume(.failure(error)) }
        let scheduled = lock.withLock { () -> Bool in
            guard !done else { return false }
            deadline = item
            return true
        }
        guard scheduled else { return }
        let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds)), execute: item)
    }

    /// A deadline is still scheduled.
    var isExpiring: Bool { lock.withLock { deadline != nil } }

    func resume(_ result: Result<T, Error>) {
        let (continuation, deadline) = lock.withLock { () -> (CheckedContinuation<T, Error>?, DispatchWorkItem?) in
            guard !done else { return (nil, nil) }
            done = true
            defer { self.continuation = nil; self.deadline = nil }
            return (self.continuation, self.deadline)
        }
        deadline?.cancel()
        continuation?.resume(with: result)
    }
}
