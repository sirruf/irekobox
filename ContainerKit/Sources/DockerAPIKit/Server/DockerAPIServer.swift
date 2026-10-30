import Foundation
import os

/// HTTP/1.1 server for the Docker Engine API on a Unix socket: keep-alive,
/// pipelined requests, chunked bodies both ways, and connection hijacking
/// for attach/exec. Written for what Docker clients do, not general HTTP.
public final class DockerAPIServer: @unchecked Sendable {
    public let socketPath: String
    private let router: DockerRouter
    private let serverName: String
    private var listener: UnixSocketListener?
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.irekobox", category: "docker-api")

    public init(socketPath: String, router: DockerRouter, serverName: String = "Irekobox") {
        self.socketPath = socketPath
        self.router = router
        self.serverName = serverName
    }

    /// Start listening. Throws if the socket is in use by a live server.
    public func start() throws {
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let listener = try UnixSocketListener(path: socketPath) { [weak self] connection in
            guard let self else { return }
            Task { await self.serve(connection) }
        }
        lock.withLock { self.listener = listener }
        log.info("Docker API listening on \(self.socketPath, privacy: .public)")
    }

    public func stop() {
        lock.withLock {
            listener?.stop()
            listener = nil
        }
    }

    // MARK: - Connection loop

    func serve(_ connection: SocketConnection) async {
        var parser = HTTPParser()
        defer { connection.close() }
        while true {
            let request: HTTPRequest
            do {
                guard let next = try parser.next() else {
                    guard let data = await connection.reader.next() else { return }
                    parser.feed(data)
                    continue
                }
                request = next
            } catch let error as HTTPParser.ParseError {
                let response = HTTPResponse.error(error.status, "\(error)")
                try? await write(response, for: nil, keepAlive: false, to: connection)
                return
            } catch {
                return
            }

            let started = ContinuousClock.now
            let response = await router.handle(request)
            // A body spilled to disk is gone once the response is written.
            defer { if let file = request.bodyFile { HTTPRequest.removeBodyFile(file) } }
            if Self.trace {
                FileHandle.standardError.write(Data("[docker-api] \(Self.clock()) \(request.method) \(request.target) -> \(response.status)\(request.wantsUpgrade ? " (upgrade)" : ""), \(Self.milliseconds(since: started)) ms\n".utf8))
            }
            if case .hijack(let handler) = response.body {
                // Bytes past the request belong to the raw stream.
                connection.reader.pushBack(parser.takeRemaining())
                do {
                    try await writeHead(hijackHead(response, request: request), to: connection)
                } catch {
                    return
                }
                await handler(connection)
                return
            }
            // A streamed body watches the input for hang-ups, which ends the
            // input stream too: such a connection isn't reused.
            var keepAlive = request.keepAlive
            if case .stream = response.body { keepAlive = false }
            do {
                try await write(response, for: request, keepAlive: keepAlive, to: connection)
            } catch {
                return
            }
            if !keepAlive { return }
        }
    }

    private func write(_ response: HTTPResponse, for request: HTTPRequest?, keepAlive: Bool,
                       to connection: SocketConnection) async throws {
        let isHead = request?.method == "HEAD"
        var headers = response.headers
        headers.append(("Connection", keepAlive ? "keep-alive" : "close"))
        switch response.body {
        case .data(let data):
            headers.append(("Content-Length", "\(data.count)"))
            var out = head(status: response.status, headers: headers)
            if !isHead { out.append(data) }
            try await connection.write(out)
        case .stream(let stream):
            headers.append(("Transfer-Encoding", "chunked"))
            try await connection.write(head(status: response.status, headers: headers))
            if isHead { return }
            try await pump(stream, to: connection)
        case .hijack:
            break   // handled by the caller
        }
    }

    /// Send a stream as chunks until it ends, or stop it when the client goes
    /// away (an idle `events` stream would otherwise never notice).
    private func pump(_ stream: AsyncThrowingStream<Data, Error>, to connection: SocketConnection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await data in stream where !data.isEmpty {
                    var chunk = Data(String(data.count, radix: 16).utf8)
                    chunk.append(Self.crlf)
                    chunk.append(data)
                    chunk.append(Self.crlf)
                    try await connection.write(chunk)
                }
                try await connection.write(Data("0\r\n\r\n".utf8))
            }
            group.addTask {
                // Drain (and ignore) input until EOF: a client that hangs up
                // ends the stream.
                while await connection.reader.next() != nil {}
                throw CancellationError()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func hijackHead(_ response: HTTPResponse, request: HTTPRequest) -> Data {
        var headers = response.headers
        if request.wantsUpgrade {
            headers.append(("Connection", "Upgrade"))
            headers.append(("Upgrade", request.header("Upgrade") ?? "tcp"))
            return head(status: 101, headers: headers)
        }
        return head(status: response.status == 101 ? 200 : response.status, headers: headers)
    }

    private func writeHead(_ data: Data, to connection: SocketConnection) async throws {
        try await connection.write(data)
    }

    private func head(status: Int, headers: [(name: String, value: String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        let standard: [(String, String)] = [
            ("Api-Version", DockerAPIVersion.current.description),
            ("Docker-Experimental", "false"),
            ("Ostype", "linux"),
            ("Server", "\(serverName) (darwin)"),
            ("Date", Self.httpDate()),
        ]
        for (name, value) in standard where !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            text += "\(name): \(value)\r\n"
        }
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static let crlf = Data([0x0D, 0x0A])
    /// DOCKER_API_TRACE=1: one line per request on stderr (conformance runs).
    private static let trace = ProcessInfo.processInfo.environment["DOCKER_API_TRACE"] == "1"

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Wall-clock time with milliseconds, to line trace entries up with other logs.
    private static func clock() -> String {
        let now = Date().timeIntervalSince1970
        let seconds = Int(now) % 60
        return String(format: "%02d.%03d", seconds, Int((now - now.rounded(.down)) * 1000))
    }

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func httpDate(_ date: Date = Date()) -> String {
        dateFormatter.string(from: date)
    }
}
