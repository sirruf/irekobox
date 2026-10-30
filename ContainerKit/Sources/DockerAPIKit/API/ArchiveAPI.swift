import Foundation
import ContainerKit

/// `docker cp` (archive HEAD/GET/PUT), `docker export` and `docker top`.
///
/// Files move with `container cp` (running containers only); archives are
/// made and unpacked with the system's bsdtar in a private temporary folder.
public enum ArchiveAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend,
                                pending: PendingCopies = PendingCopies()) {
        let directory = ContainerDirectory(backend: backend)
        router.add("HEAD", "/containers/{id}/archive") { request in
            await respond {
                if let stat = try await createdStat(request, directory) {
                    return HTTPResponse(status: 200, headers: [("X-Docker-Container-Path-Stat", stat.header)])
                }
                let (item, path) = try await target(request, directory)
                let stat = try await statPath(path, in: item, backend)
                return HTTPResponse(status: 200, headers: [("X-Docker-Container-Path-Stat", stat.header)])
            }
        }
        router.add("GET", "/containers/{id}/archive") { request in
            await respond { try await get(request, directory, backend) }
        }
        router.add("PUT", "/containers/{id}/archive") { request in
            await respond { try await put(request, directory, backend, pending) }
        }
        router.add("GET", "/containers/{id}/export") { request in
            await respond { try await export(request, directory, backend) }
        }
        router.add("GET", "/containers/{id}/top") { request in
            await respond { try await top(request, directory, backend) }
        }
    }

    // MARK: - Path stat

    struct PathStat: Encodable {
        let name: String
        let size: Int64
        /// Go's os.FileMode (type bits high), which the docker CLI decodes.
        let mode: UInt32
        let mtime: String
        let linkTarget: String

        var isDirectory: Bool { mode & (1 << 31) != 0 }

        var header: String {
            let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
            return data.base64EncodedString()
        }
    }

    /// Unix st_mode → Go os.FileMode.
    static func goFileMode(_ unix: UInt32) -> UInt32 {
        var mode = unix & 0o777
        switch unix & 0o170000 {
        case 0o040000: mode |= 1 << 31                      // dir
        case 0o120000: mode |= 1 << 27                      // symlink
        case 0o010000: mode |= 1 << 25                      // named pipe
        case 0o140000: mode |= 1 << 24                      // socket
        case 0o020000: mode |= (1 << 26) | (1 << 21)        // char device
        case 0o060000: mode |= 1 << 26                      // block device
        default: break
        }
        if unix & 0o4000 != 0 { mode |= 1 << 23 }           // setuid
        if unix & 0o2000 != 0 { mode |= 1 << 22 }           // setgid
        if unix & 0o1000 != 0 { mode |= 1 << 20 }           // sticky
        return mode
    }

    static func target(_ request: DockerRequest, _ directory: ContainerDirectory) async throws -> (DockerContainer, String) {
        let item = try await directory.resolve(request.parameters["id"]!)
        guard let path = request.query["path"], !path.isEmpty else {
            throw DockerAPIError.badParameter("path is required")
        }
        guard item.state == .running else {
            throw DockerAPIError(409, "Irekobox copies files only while the container runs: start \(item.name) first")
        }
        return (item, path)
    }

    /// Directories every Linux image has.
    static let standardDirectories: Set<String> = ["/", "/bin", "/etc", "/home", "/lib", "/mnt", "/opt", "/root",
                                                   "/run", "/sbin", "/srv", "/tmp", "/usr", "/usr/bin", "/usr/lib",
                                                   "/usr/local", "/usr/local/bin", "/usr/share", "/var", "/var/lib"]

    /// A created container can't be looked into (its VM isn't up): standard
    /// directories and paths ending in "/" are taken as directories, anything
    /// else as missing, which the CLI copies to as a new name. nil when the
    /// container has run.
    static func createdStat(_ request: DockerRequest, _ directory: ContainerDirectory) async throws -> PathStat? {
        let item = try await directory.resolve(request.parameters["id"]!)
        guard item.state == .created, let path = request.query["path"], !path.isEmpty else { return nil }
        return try assumedStat(path, in: item.name)
    }

    static func assumedStat(_ path: String, in name: String) throws -> PathStat {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
        guard path.hasSuffix("/") || standardDirectories.contains(normalized) else {
            throw DockerAPIError(404, "Could not find the file \(path) in container \(name)")
        }
        let last = (normalized as NSString).lastPathComponent
        return PathStat(name: last.isEmpty ? "/" : last, size: 4096, mode: goFileMode(0o040755),
                        mtime: DockerTime.zero, linkTarget: "")
    }

    /// `stat` inside the container (busybox and coreutils both take -c).
    static func statPath(_ path: String, in item: DockerContainer, _ backend: DockerBackend) async throws -> PathStat {
        let output: Data
        do {
            output = try await backend.execute(item.name, command: ["stat", "-c", "%s|%f|%Y", "--", path])
        } catch {
            let message = error.localizedDescription
            if message.contains("No such file") || message.contains("can't stat") || message.contains("cannot stat") {
                throw DockerAPIError(404, "Could not find the file \(path) in container \(item.name)")
            }
            if message.contains("failed to find target executable") {
                throw DockerAPIError(500, "The image has no stat tool, so \(path) can't be inspected")
            }
            throw DockerAPIError(500, message)
        }
        let fields = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|")
        guard fields.count == 3, let size = Int64(fields[0]), let unix = UInt32(fields[1], radix: 16),
              let seconds = TimeInterval(fields[2]) else {
            throw DockerAPIError(404, "Could not find the file \(path) in container \(item.name)")
        }
        let mode = goFileMode(unix)
        var link = ""
        if unix & 0o170000 == 0o120000 {
            link = String(decoding: (try? await backend.execute(item.name, command: ["readlink", "--", path])) ?? Data(),
                          as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = (path as NSString).lastPathComponent
        return PathStat(name: name.isEmpty ? "/" : name, size: size, mode: mode,
                        mtime: DockerTime.string(Date(timeIntervalSince1970: seconds)), linkTarget: link)
    }

    // MARK: - GET / PUT

    static func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "irekobox-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// `docker cp ctr:/path …`: a tar of the file or folder, named as its last
    /// path component, plus the stat header.
    static func get(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let (item, path) = try await target(request, directory)
        let stat = try await statPath(path, in: item, backend)
        let folder = try scratch()
        let name = stat.name == "/" ? "root" : stat.name
        do {
            try await backend.copy(from: "\(item.name):\(path)", to: folder.appending(path: name).path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw DockerAPIError(500, "copying \(path) out of \(item.name) failed: \(error.localizedDescription)")
        }
        let stream = Tar.create(entry: name, in: folder) {
            try? FileManager.default.removeItem(at: folder)
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-tar"),
                                                   ("X-Docker-Container-Path-Stat", stat.header)],
                            body: .stream(stream))
    }

    /// `docker cp … ctr:/dir`: unpack the tar and copy each top-level entry
    /// into the (existing) directory.
    static func put(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend,
                    _ pending: PendingCopies) async throws -> HTTPResponse {
        // Into a container that never ran (buildx writes its config before
        // starting BuildKit): kept and copied in right after the first start.
        // Docker copies before the process runs; the apiserver can't, so a
        // process that reads the file at once may miss it.
        let created = try await directory.resolve(request.parameters["id"]!)
        if created.state == .created, let path = request.query["path"], !path.isEmpty {
            let folder = try scratch()
            do {
                try await Tar.extract(request.http.body, into: folder)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            await pending.add(created.name, folder: folder, path: path)
            return HTTPResponse(status: 200)
        }
        let (item, path) = try await target(request, directory)
        let stat = try await statPath(path, in: item, backend)
        guard stat.isDirectory else {
            throw DockerAPIError.badParameter("extraction point is not a directory: \(path)")
        }
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Tar.extract(request.http.body, into: folder)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for entry in entries {
            do {
                try await backend.copy(from: folder.appending(path: entry).path, to: "\(item.name):\(path)")
            } catch {
                throw DockerAPIError(500, "copying \(entry) into \(item.name):\(path) failed: \(error.localizedDescription)")
            }
        }
        return HTTPResponse(status: 200)
    }

    // MARK: - Export / top

    static func export(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let item = try await directory.resolve(request.parameters["id"]!)
        guard item.state != .created else {
            throw DockerAPIError(409, "\(item.name) has never run, so it has no filesystem to export yet")
        }
        let folder = try scratch()
        let file = folder.appending(path: "export.tar")
        do {
            try await backend.exportContainer(item.name, to: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw DockerAPIError(500, "export failed: \(error.localizedDescription)")
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-tar")],
                            body: .stream(Tar.read(file) { try? FileManager.default.removeItem(at: folder) }))
    }

    struct TopResponse: Encodable {
        let Titles: [String]
        let Processes: [[String]]
    }

    /// `ps` inside the container: busybox prints PID USER TIME COMMAND.
    static func top(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let item = try await directory.resolve(request.parameters["id"]!)
        guard item.state == .running else {
            throw DockerAPIError(409, "Container \(item.id) is not running")
        }
        let args = (request.query["ps_args"] ?? "").split(separator: " ").map(String.init)
        let output: Data
        do {
            output = try await backend.execute(item.name, command: ["ps"] + args)
        } catch {
            throw DockerAPIError(500, "ps failed in \(item.name): \(error.localizedDescription)")
        }
        return .json(parsePS(String(decoding: output, as: UTF8.self)))
    }

    /// Header columns are the titles; the last column takes the rest of the line.
    static func parsePS(_ text: String) -> TopResponse {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return TopResponse(Titles: [], Processes: []) }
        let titles = header.split(separator: " ").map(String.init)
        let rows = lines.dropFirst().map { line -> [String] in
            let parts = line.split(separator: " ", maxSplits: max(0, titles.count - 1), omittingEmptySubsequences: true)
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return TopResponse(Titles: titles, Processes: rows)
    }
}

/// bsdtar without macOS metadata (no `._` AppleDouble files, no xattrs).
enum Tar {
    private static func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        return process
    }

    /// Stream `tar -c` of `entry` inside `folder`; `done` runs at the end.
    static func create(entry: String, in folder: URL, done: @escaping @Sendable () -> Void) -> AsyncThrowingStream<Data, Error> {
        let tar = process(["--no-mac-metadata", "--no-xattrs", "-c", "-f", "-", "-C", folder.path, entry])
        return pipeOut(tar, done: done)
    }

    static func read(_ file: URL, done: @escaping @Sendable () -> Void) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global().async {
                defer { done() }
                guard let handle = try? FileHandle(forReadingFrom: file) else {
                    continuation.finish(throwing: DockerAPIError(500, "export file missing"))
                    return
                }
                while let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                try? handle.close()
                continuation.finish()
            }
        }
    }

    static func extract(_ archive: Data, into folder: URL) async throws {
        let tar = process(["-x", "-f", "-", "-C", folder.path])
        let input = Pipe()
        let errors = Pipe()
        tar.standardInput = input
        tar.standardError = errors
        // terminationHandler, not waitUntilExit: the latter waits on a run
        // loop that a worker thread doesn't spin.
        let exited = AsyncStream<Void> { continuation in
            tar.terminationHandler = { _ in continuation.finish() }
        }
        try tar.run()
        let writer = input.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: archive)
            try? writer.close()
        }
        for await _ in exited {}
        guard tar.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DockerAPIError.badParameter("invalid tar archive: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func pipeOut(_ tar: Process, done: @escaping @Sendable () -> Void) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let output = Pipe()
            tar.standardOutput = output
            tar.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            tar.terminationHandler = { _ in exited.signal() }
            do {
                try tar.run()
            } catch {
                done()
                continuation.finish(throwing: error)
                return
            }
            DispatchQueue.global().async {
                let handle = output.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                exited.wait()
                done()
                if tar.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: DockerAPIError(500, "tar failed with status \(tar.terminationStatus)"))
                }
            }
            continuation.onTermination = { _ in
                if tar.isRunning { tar.terminate() }
            }
        }
    }
}

/// Archives sent to created containers, copied in right after they start.
public actor PendingCopies {
    struct Copy {
        let folder: URL
        let path: String
    }
    private var copies: [String: [Copy]] = [:]

    public init() {}

    func add(_ name: String, folder: URL, path: String) {
        copies[name, default: []].append(Copy(folder: folder, path: path))
    }

    /// Copy everything kept for `name` (it must be running), then forget it.
    func apply(_ name: String, backend: DockerBackend) async throws {
        let list = copies.removeValue(forKey: name) ?? []
        defer { for copy in list { try? FileManager.default.removeItem(at: copy.folder) } }
        for copy in list {
            for entry in try FileManager.default.contentsOfDirectory(atPath: copy.folder.path).sorted() {
                do {
                    try await backend.copy(from: copy.folder.appending(path: entry).path, to: "\(name):\(copy.path)")
                } catch {
                    throw DockerAPIError(500, "copying \(entry) into \(name):\(copy.path) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func forget(_ name: String) {
        for copy in copies.removeValue(forKey: name) ?? [] { try? FileManager.default.removeItem(at: copy.folder) }
    }
}
