import Foundation
import ContainerKit

/// One `docker exec`: created by `POST /containers/{id}/exec`, run by
/// `POST /exec/{id}/start`, inspected for its exit code.
struct ExecRecord: Sendable {
    let id: String
    let container: String
    let containerDockerID: String
    let spec: ProcessSpec
    let attachStdin: Bool
    let attachStdout: Bool
    let attachStderr: Bool
    var started = false
    var running = false
    var exitCode: Int32?
}

public actor ExecRegistry {
    private var records: [String: ExecRecord] = [:]

    public init() {}

    func add(_ record: ExecRecord) { records[record.id] = record }
    func get(_ id: String) -> ExecRecord? { records[id] }

    /// Mark started; false if it already was (an exec runs once).
    func begin(_ id: String) -> Bool {
        guard var record = records[id], !record.started else { return false }
        record.started = true
        record.running = true
        records[id] = record
        return true
    }

    func finish(_ id: String, code: Int32?) {
        records[id]?.running = false
        records[id]?.exitCode = code
    }
}

/// Attach to a container's init process and exec in it, over hijacked
/// connections; resize their TTYs.
public enum ExecAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend,
                                attaches: AttachRegistry, execs: ExecRegistry, exits: ExitRecorder?) {
        let directory = ContainerDirectory(backend: backend, exits: exits)

        router.add("POST", "/containers/{id}/attach") { request in
            await respond { try await attach(request, directory, backend, attaches) }
        }
        router.add("POST", "/containers/{id}/resize") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                guard item.state == .running else {
                    throw DockerAPIError(409, "Container \(item.id) is not running")
                }
                let (width, height) = try size(request)
                try await ContainersAPI.engine {
                    try await backend.resizeProcess(item.name, process: item.name, width: width, height: height)
                }
                return HTTPResponse(status: 200)
            }
        }
        router.add("POST", "/containers/{id}/exec") { request in
            await respond { try await createExec(request, directory, execs) }
        }
        router.add("POST", "/exec/{id}/start") { request in
            await respond { try await startExec(request, backend, execs) }
        }
        router.add("POST", "/exec/{id}/resize") { request in
            await respond {
                let id = request.parameters["id"]!
                guard let record = await execs.get(id) else { throw DockerAPIError(404, "No such exec instance: \(id)") }
                let (width, height) = try size(request)
                try await ContainersAPI.engine {
                    try await backend.resizeProcess(record.container, process: id, width: width, height: height)
                }
                return HTTPResponse(status: 201)
            }
        }
        router.add("GET", "/exec/{id}/json") { request in
            await respond {
                let id = request.parameters["id"]!
                guard let record = await execs.get(id) else { throw DockerAPIError(404, "No such exec instance: \(id)") }
                return .json(inspect(record))
            }
        }
    }

    static func size(_ request: DockerRequest) throws -> (Int, Int) {
        guard let height = try request.int("h"), let width = try request.int("w") else {
            throw DockerAPIError.badParameter("h and w are required")
        }
        return (width, height)
    }

    // MARK: - Attach

    static func attach(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend,
                       _ attaches: AttachRegistry) async throws -> HTTPResponse {
        let item = try await directory.resolve(request.parameters["id"]!)
        let name = item.name
        let tty = item.container.configuration.initProcess.terminal ?? false
        let wantsStdin = request.bool("stdin")
        let wantsStdout = request.bool("stdout")
        let wantsStderr = request.bool("stderr")
        let type = tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"

        if item.state == .running {
            // The runtime attaches stdio only when it starts a process: for a
            // running container, show its output (no stdin), like `logs -f`.
            return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: .hijack { connection in
                guard wantsStdout || wantsStderr else { return }
                for await line in Self.follow(name, backend: backend, directory: directory) {
                    let payload = Data((line + "\n").utf8)
                    try? await connection.write(tty ? payload : LogsStatsAPI.frame(payload))
                }
                connection.closeWrite()
            })
        }

        // Before start (`docker run -it`, `docker start -ai`): leave a bridge
        // for `start` to boot the container with.
        let bridge = StdioBridge(stdin: wantsStdin, stdout: wantsStdout, stderr: wantsStderr, tty: tty)
        await attaches.register(bridge, for: name)
        return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: .hijack { connection in
            await bridge.run(on: connection)
            await attaches.remove(bridge, for: name)
            connection.closeWrite()
        })
    }

    /// New output lines of a running container until it stops.
    static func follow(_ name: String, backend: DockerBackend, directory: ContainerDirectory) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                var count = 0
                for try await _ in backend.containerLogs(name, follow: false) { count += 1 }
                let history = count
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var remaining = history
                        do {
                            for try await line in backend.containerLogs(name, follow: true) {
                                if remaining > 0 { remaining -= 1; continue }
                                continuation.yield(line)
                            }
                        } catch {}
                    }
                    group.addTask {
                        while (try? await directory.resolve(name))?.state == .running {
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Boot a created container with an attached client's stdio (called by
    /// `start`); false when nobody is attached.
    static func startAttached(_ name: String, backend: DockerBackend, attaches: AttachRegistry,
                              beforeStart: @Sendable () async -> Void = {}) async throws -> Bool {
        guard let bridge = await attaches.take(name) else { return false }
        do {
            try await backend.bootstrapContainer(name, stdio: bridge.stdio)
            bridge.closeContainerEnds()
            await beforeStart()
            try await backend.startProcess(name, process: name)
            bridge.markStarted()
            return true
        } catch {
            bridge.closeContainerEnds()
            throw error
        }
    }

    // MARK: - Exec

    struct ExecConfig: Decodable {
        let AttachStdin: Bool?
        let AttachStdout: Bool?
        let AttachStderr: Bool?
        let Tty: Bool?
        let Cmd: [String]?
        let Env: [String]?
        let WorkingDir: String?
        let User: String?
        let Privileged: Bool?
    }

    static func createExec(_ request: DockerRequest, _ directory: ContainerDirectory, _ execs: ExecRegistry) async throws -> HTTPResponse {
        let item = try await directory.resolve(request.parameters["id"]!)
        guard item.state == .running else {
            throw DockerAPIError(409, "container \(item.id) is not running")
        }
        let config: ExecConfig
        do {
            config = try JSONDecoder().decode(ExecConfig.self, from: request.http.body.isEmpty ? Data("{}".utf8) : request.http.body)
        } catch {
            throw DockerAPIError.badParameter("invalid exec config: \(error.localizedDescription)")
        }
        guard let command = config.Cmd, let executable = command.first, !executable.isEmpty else {
            throw DockerAPIError.badParameter("No exec command specified")
        }
        if config.Privileged == true {
            throw DockerAPIError.badParameter("Privileged exec is not supported by Irekobox")
        }
        let process = item.container.configuration.initProcess
        // The container's environment, overridden per key by the exec's.
        var environment = process.environment
        for entry in config.Env ?? [] {
            let key = entry.split(separator: "=", maxSplits: 1).first.map(String.init) ?? entry
            environment.removeAll { $0 == key || $0.hasPrefix(key + "=") }
            environment.append(entry)
        }
        let user: ProcessSpec.User
        if let text = config.User, !text.isEmpty {
            user = .raw(userString: text)
        } else {
            user = process.user ?? .id(uid: 0, gid: 0)
        }
        let workingDirectory = config.WorkingDir.flatMap { $0.isEmpty ? nil : $0 } ?? process.workingDirectory
        let spec = ProcessSpec(executable: executable, arguments: Array(command.dropFirst()), environment: environment,
                               workingDirectory: workingDirectory.isEmpty ? "/" : workingDirectory,
                               terminal: config.Tty ?? false, user: user)
        let id = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        await execs.add(ExecRecord(id: id, container: item.name, containerDockerID: item.id, spec: spec,
                                   attachStdin: config.AttachStdin ?? false,
                                   attachStdout: config.AttachStdout ?? true,
                                   attachStderr: config.AttachStderr ?? true))
        return .json(["Id": id], status: 201)
    }

    struct StartConfig: Decodable {
        let Detach: Bool?
        let Tty: Bool?
    }

    static func startExec(_ request: DockerRequest, _ backend: DockerBackend, _ execs: ExecRegistry) async throws -> HTTPResponse {
        let id = request.parameters["id"]!
        guard let record = await execs.get(id) else { throw DockerAPIError(404, "No such exec instance: \(id)") }
        let start = (try? JSONDecoder().decode(StartConfig.self, from: request.http.body)) ?? StartConfig(Detach: nil, Tty: nil)
        guard await execs.begin(id) else { throw DockerAPIError(409, "Exec instance \(id) has already been started") }
        let container = record.container

        if start.Detach == true {
            try await ContainersAPI.engine {
                try await backend.createProcess(container, process: id, spec: record.spec, stdio: ProcessStdio())
                try await backend.startProcess(container, process: id)
            }
            Task {
                let exit = try? await backend.waitProcess(container, process: id)
                await execs.finish(id, code: exit?.code)
            }
            return HTTPResponse(status: 200)
        }

        let tty = record.spec.terminal
        let bridge = StdioBridge(stdin: record.attachStdin, stdout: record.attachStdout,
                                 stderr: record.attachStderr, tty: tty)
        do {
            try await backend.createProcess(container, process: id, spec: record.spec, stdio: bridge.stdio)
            bridge.closeContainerEnds()
            try await backend.startProcess(container, process: id)
            bridge.markStarted()
        } catch {
            bridge.closeContainerEnds()
            // As Docker: the stream opens, carries the error, and the exec
            // exits 127 (not found) or 126 (can't run). Testcontainers' port
            // check execs a shell that images like Ryuk don't have.
            let message = "OCI runtime exec failed: \(error.localizedDescription)"
            let missing = ["no such file", "not found"].contains { message.localizedCaseInsensitiveContains($0) }
            await execs.finish(id, code: missing ? 127 : 126)
            let type = tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"
            return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: .hijack { connection in
                let payload = Data((message + "\r\n").utf8)
                if record.attachStdout || record.attachStderr {
                    try? await connection.write(tty ? payload : LogsStatsAPI.frame(payload))
                }
                connection.closeWrite()
            })
        }
        let type = tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"
        return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: .hijack { connection in
            async let exit = try? backend.waitProcess(container, process: id)
            await bridge.run(on: connection)
            // The exit code is known before the client sees EOF, so its
            // follow-up inspect reads it.
            await execs.finish(id, code: (await exit)?.code)
            connection.closeWrite()
        })
    }

    struct ExecInspect: Encodable {
        struct ProcessConfig: Encodable {
            let tty: Bool
            let entrypoint: String
            let arguments: [String]
            let privileged = false
            let user: String
        }
        let ID: String
        let Running: Bool
        let ExitCode: Int32?
        let ProcessConfig: ProcessConfig
        let OpenStdin: Bool
        let OpenStderr: Bool
        let OpenStdout: Bool
        let CanRemove = false
        let ContainerID: String
        let DetachKeys = ""
        let Pid = 0
    }

    static func inspect(_ record: ExecRecord) -> ExecInspect {
        let user: String
        switch record.spec.user {
        case .raw(let text): user = text
        case .id(let uid, let gid): user = "\(uid):\(gid)"
        }
        return ExecInspect(ID: record.id, Running: record.running, ExitCode: record.exitCode,
                           ProcessConfig: .init(tty: record.spec.terminal, entrypoint: record.spec.executable,
                                                arguments: record.spec.arguments, user: user),
                           OpenStdin: record.attachStdin, OpenStderr: record.attachStderr,
                           OpenStdout: record.attachStdout, ContainerID: record.containerDockerID)
    }
}
