import Foundation

/// Carries out a Docker Desktop migration: networks, then volumes (data
/// streamed through tar), images (`docker save | docker load`), then
/// containers (created through Irekobox's Docker API from Docker's
/// own configuration, compose labels included, so `docker compose` finds
/// its projects). What's done is saved after every item, so a later run
/// continues where this one stopped.
public actor DesktopMigrationRunner {
    public enum Status: Codable, Hashable, Sendable {
        case pending
        case running
        case done
        case failed(String)
        case skipped(String)
    }

    public struct Progress: Codable, Sendable {
        public var statuses: [String: Status] = [:]
        public var updated = Date()
    }

    public struct Options: Sendable {
        /// Start containers that were running in Docker Desktop.
        public var startRunning = true
        /// Stop a running container in Docker Desktop just before starting
        /// its copy here, so ports and files are handed over.
        public var stopSource = true
        /// Image with `tar`, used on both sides to move volume data.
        public var helperImage = "alpine:latest"

        public init(startRunning: Bool = true, stopSource: Bool = true, helperImage: String = "alpine:latest") {
            self.startRunning = startRunning
            self.stopSource = stopSource
            self.helperImage = helperImage
        }
    }

    let source: String
    let destination: String
    let docker: String
    let progressFile: URL?
    private var progress = Progress()
    private var onChange: (@Sendable (String, Status) -> Void)?

    /// - Parameters:
    ///   - source / destination: Docker API sockets (Docker Desktop, Irekobox).
    ///   - docker: the docker CLI, used to stream images and volume data.
    public init(source: String, destination: String, docker: String, progressFile: URL?) {
        self.source = source
        self.destination = destination
        self.docker = docker
        self.progressFile = progressFile
        if let progressFile, let data = try? Data(contentsOf: progressFile),
           let saved = try? JSONDecoder().decode(Progress.self, from: data) {
            progress = saved
        }
    }

    public func observe(_ handler: @escaping @Sendable (String, Status) -> Void) {
        onChange = handler
    }

    public func statuses() -> [String: Status] { progress.statuses }

    /// Forget saved progress (start over).
    public func reset() {
        progress = Progress()
        save()
    }

    /// Order items so what something needs comes first.
    public static func order(_ items: [DesktopMigration.Item]) -> [DesktopMigration.Item] {
        let rank: [DesktopMigration.Kind: Int] = [.network: 0, .volume: 1, .image: 2, .container: 3, .registry: 4]
        return items.sorted { (rank[$0.kind] ?? 9, $0.name) < (rank[$1.kind] ?? 9, $1.name) }
    }

    /// Move `selected` (plus whatever they need from `all`). Items already
    /// done in an earlier run are skipped.
    public func run(_ selected: [DesktopMigration.Item], all: [DesktopMigration.Item], options: Options) async {
        var wanted = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var queue = selected
        while let item = queue.popLast() {
            for need in item.needs where wanted[need] == nil {
                if let dependency = byID[need] {
                    wanted[need] = dependency
                    queue.append(dependency)
                }
            }
        }
        for item in Self.order(Array(wanted.values)) {
            if Task.isCancelled { return }
            if progress.statuses[item.id] == .done { continue }
            guard item.movable else {
                let reason = item.problems.first { $0.level == .blocked }?.text ?? String(localized: "not movable")
                set(item.id, item.kind == .registry ? .skipped(String(localized: "sign in again", comment: "Why a registry sign-in was skipped during migration")) : .skipped(reason))
                continue
            }
            if let blocked = item.needs.first(where: { need in
                if case .failed = progress.statuses[need] ?? .pending { return true }
                if case .skipped = progress.statuses[need] ?? .pending { return byID[need]?.kind != .registry }
                return false
            }) {
                set(item.id, .skipped(String(localized: "needs \(byID[blocked]?.name ?? blocked), which didn't move")))
                continue
            }
            set(item.id, .running)
            do {
                try await move(item, options: options)
                set(item.id, .done)
            } catch {
                set(item.id, .failed(error.localizedDescription))
            }
        }
    }

    private func set(_ id: String, _ status: Status) {
        progress.statuses[id] = status
        progress.updated = Date()
        save()
        onChange?(id, status)
    }

    private func save() {
        guard let progressFile, let data = try? JSONEncoder().encode(progress) else { return }
        try? FileManager.default.createDirectory(at: progressFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: progressFile, options: .atomic)
    }

    // MARK: - Steps

    public struct StepError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private var api: UnixHTTP { UnixHTTP(socketPath: destination) }

    private func move(_ item: DesktopMigration.Item, options: Options) async throws {
        switch item.kind {
        case .network: try await moveNetwork(item)
        case .volume: try await moveVolume(item, options: options)
        case .image: try await moveImage(item)
        case .container: try await moveContainer(item, options: options)
        case .registry: break
        }
    }

    private func check(_ response: UnixHTTP.Response, _ what: String, allow: Set<Int> = []) throws {
        guard response.ok || allow.contains(response.status) else {
            throw StepError(message: "\(what): \(response.message)")
        }
    }

    private func moveNetwork(_ item: DesktopMigration.Item) async throws {
        if try await api.get("/networks/\(escape(item.name))").ok { return }    // already there
        try check(try await api.post("/networks/create", json: item.payload.create?.any), String(localized: "creating network", comment: "Step of moving an item from Docker Desktop, shown before the error"))
    }

    private func moveVolume(_ item: DesktopMigration.Item, options: Options) async throws {
        if !(try await api.get("/volumes/\(escape(item.name))").ok) {
            try check(try await api.post("/volumes/create", json: item.payload.create?.any), String(localized: "creating volume", comment: "Step of moving an item from Docker Desktop, shown before the error"))
        }
        let label = ["--label", "com.irekobox.migration=1"]
        try await Pipeline.run(
            [docker, "--host", "unix://\(source)", "run", "--rm"] + label
                + ["-v", "\(item.name):/from:ro", options.helperImage, "tar", "-C", "/from", "-cf", "-", "."],
            [docker, "--host", "unix://\(destination)", "run", "--rm", "-i"] + label
                + ["-v", "\(item.name):/to", options.helperImage, "tar", "-C", "/to", "-xf", "-"])
    }

    private func moveImage(_ item: DesktopMigration.Item) async throws {
        let references = item.payload.references ?? [item.name]
        // One name per archive: `container image load` fails ("File exists")
        // on an archive naming the same image twice. The other tags follow.
        try await Pipeline.run([docker, "--host", "unix://\(source)", "save", references[0]],
                               [docker, "--host", "unix://\(destination)", "load", "-q"])
        for reference in references.dropFirst() {
            let (repo, tag) = Self.split(reference)
            let response = try await api.post("/images/\(escape(references[0]))/tag?repo=\(escape(repo))&tag=\(escape(tag))")
            try check(response, String(localized: "tagging \(reference)", comment: "Step of moving an item from Docker Desktop, shown before the error"))
        }
    }

    static func split(_ reference: String) -> (String, String) {
        guard let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") else { return (reference, "latest") }
        return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
    }

    private func moveContainer(_ item: DesktopMigration.Item, options: Options) async throws {
        if !(try await api.get("/containers/\(escape(item.name))/json").ok) {
            guard var body = item.payload.create?.any as? [String: Any] else { throw StepError(message: String(localized: "no configuration", comment: "Error: a container to migrate has no saved configuration")) }
            // Mark where it came from; compose labels stay as they were.
            var labels = body["Labels"] as? [String: Any] ?? [:]
            labels["com.irekobox.migrated-from"] = "docker-desktop"
            body["Labels"] = labels
            if let image = body["Image"] as? String, !(try await api.get("/images/\(escape(image))/json").ok) {
                let (repo, tag) = Self.split(image)
                let pull = try await api.post("/images/create?fromImage=\(escape(repo))&tag=\(escape(tag))", timeout: 1800)
                try check(pull, String(localized: "pulling \(image)", comment: "Step of moving an item from Docker Desktop, shown before the error"))
            }
            let created = try await api.post("/containers/create?name=\(escape(item.name))", json: body)
            try check(created, String(localized: "creating container", comment: "Step of moving an item from Docker Desktop, shown before the error"))
        }
        if options.startRunning, item.payload.wasRunning == true {
            if options.stopSource {
                let stopped = try await UnixHTTP(socketPath: source).post("/containers/\(escape(item.name))/stop?t=10", timeout: 60)
                try check(stopped, String(localized: "stopping it in Docker Desktop", comment: "Step of moving an item from Docker Desktop, shown before the error"), allow: [304, 404])
            }
            let started = try await api.post("/containers/\(escape(item.name))/start", timeout: 300)
            if started.message.contains("Address already in use") {
                throw StepError(message: String(localized: "Created, but not started: one of its ports is in use (still running in Docker Desktop?)"))
            }
            try check(started, String(localized: "starting", comment: "Step of moving an item from Docker Desktop, shown before the error"), allow: [304])
        }
    }

    private func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))) ?? text
    }
}

/// `a | b` with both processes' errors reported.
enum Pipeline {
    static func run(_ first: [String], _ second: [String]) async throws {
        let producer = Process()
        producer.executableURL = URL(fileURLWithPath: first[0])
        producer.arguments = Array(first.dropFirst())
        let consumer = Process()
        consumer.executableURL = URL(fileURLWithPath: second[0])
        consumer.arguments = Array(second.dropFirst())
        let pipe = Pipe()
        producer.standardOutput = pipe
        consumer.standardInput = pipe
        let producerErrors = Pipe()
        let consumerErrors = Pipe()
        producer.standardError = producerErrors
        consumer.standardError = consumerErrors
        consumer.standardOutput = FileHandle.nullDevice

        let finished = AsyncStream<Void> { continuation in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            producer.terminationHandler = { _ in group.leave() }
            consumer.terminationHandler = { _ in group.leave() }
            group.notify(queue: .global()) { continuation.finish() }
        }
        try consumer.run()
        do {
            try producer.run()
        } catch {
            consumer.terminate()
            throw error
        }
        // Our copies of the pipe ends would keep the consumer's stdin open.
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        let collected = Collected()
        Self.drain(producerErrors, into: collected, first: true)
        Self.drain(consumerErrors, into: collected, first: false)
        for await _ in finished {}
        guard producer.terminationStatus == 0, consumer.terminationStatus == 0 else {
            let failed = producer.terminationStatus != 0 ? collected.first : collected.second
            let text = failed.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopMigrationRunner.StepError(message: text.isEmpty ? String(localized: "command failed") : String(text.suffix(400)))
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var a = Data(), b = Data()
        func add(_ data: Data, first: Bool) { lock.withLock { if first { a += data } else { b += data } } }
        var first: String { lock.withLock { String(decoding: a, as: UTF8.self) } }
        var second: String { lock.withLock { String(decoding: b, as: UTF8.self) } }
    }

    static func drain(_ pipe: Pipe, into collected: Collected, first: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collected.add(data, first: first) }
        }
    }
}
