import XCTest
import Darwin
@testable import DockerAPIKit

/// The server over a real Unix socket, driven by a raw client.
final class DockerAPIServerTests: XCTestCase {

    private var server: DockerAPIServer!
    private var path: String!

    override func setUp() async throws {
        // sun_path is ~104 bytes: keep the socket path short.
        path = "/tmp/ib-test-\(UUID().uuidString.prefix(8)).sock"
        var router = DockerRouter()
        router.add("GET", "/_ping") { _ in .text("OK") }
        router.add("POST", "/echo") { request in
            HTTPResponse(status: 200, body: .data(request.http.body))
        }
        router.add("GET", "/stream") { _ in
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            Task {
                for line in ["{\"n\":1}\n", "{\"n\":2}\n", "{\"n\":3}\n"] {
                    continuation.yield(Data(line.utf8))
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continuation.finish()
            }
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
        }
        router.add("GET", "/big") { _ in
            // Several MB: far beyond a socket's send buffer.
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            Task {
                for index in 0..<40 { continuation.yield(Data(repeating: UInt8(index), count: 256 << 10)) }
                continuation.finish()
            }
            return HTTPResponse(status: 200, body: .stream(stream))
        }
        router.add("GET", "/bigdata") { _ in
            HTTPResponse(status: 200, body: .data(Data(repeating: 7, count: 8 << 20)))
        }
        router.add("POST", "/attach") { _ in
            HTTPResponse(status: 200, headers: [("Content-Type", "application/vnd.docker.raw-stream")],
                         body: .hijack { connection in
                // Echo until the client half-closes, then say goodbye.
                for await data in connection.input {
                    try? await connection.write(data)
                }
                try? await connection.write(Data("bye".utf8))
                connection.closeWrite()
            })
        }
        server = DockerAPIServer(socketPath: path, router: router)
        try server.start()
    }

    override func tearDown() async throws {
        server.stop()
    }

    // MARK: - Client helpers

    private func connect() throws -> SocketConnection {
        try XCTUnwrap(SocketConnection.connect(to: path))
    }

    /// Read until `done` says the bytes so far are complete (or EOF / 5 s).
    private func read(_ connection: SocketConnection, until done: (Data) -> Bool) async -> Data {
        var received = Data()
        let deadline = Date().addingTimeInterval(5)
        while !done(received), Date() < deadline {
            guard let chunk = await withTaskGroup(of: Data?.self, body: { group in
                group.addTask { await connection.reader.next() }
                group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }) else { break }
            received.append(chunk)
        }
        return received
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: - Tests

    func testKeepAliveServesSeveralRequestsOnOneConnection() async throws {
        let client = try connect()
        defer { client.close() }
        try await client.write(Data("GET /_ping HTTP/1.1\r\nHost: docker\r\n\r\n".utf8))
        let first = text(await read(client) { self.text($0).hasSuffix("\r\n\r\nOK") })
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 200 OK\r\n"), first)
        XCTAssertTrue(first.contains("Api-Version: 1.56\r\n"))
        XCTAssertTrue(first.contains("Ostype: linux\r\n"))
        XCTAssertTrue(first.contains("Content-Length: 2\r\n"))

        // Same connection, a body split over two writes.
        try await client.write(Data("POST /v1.44/echo HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello".utf8))
        try await client.write(Data(" world".utf8))
        let second = text(await read(client) { self.text($0).hasSuffix("hello world") })
        XCTAssertTrue(second.hasPrefix("HTTP/1.1 200 OK\r\n"), second)
    }

    func testUnknownPathAndBadRequest() async throws {
        let client = try connect()
        defer { client.close() }
        try await client.write(Data("GET /v1.56/nope HTTP/1.1\r\n\r\n".utf8))
        let notFound = text(await read(client) { self.text($0).contains("}\n") })
        XCTAssertTrue(notFound.hasPrefix("HTTP/1.1 404 Not Found\r\n"), notFound)
        XCTAssertTrue(notFound.contains(#"{"message":"page not found"}"#))

        let bad = try connect()
        defer { bad.close() }
        try await bad.write(Data("NONSENSE\r\n\r\n".utf8))
        let response = text(await read(bad) { self.text($0).contains("}\n") })
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"), response)
        XCTAssertTrue(response.contains("Connection: close"))
    }

    func testStreamsChunkedThenCloses() async throws {
        let client = try connect()
        defer { client.close() }
        try await client.write(Data("GET /stream HTTP/1.1\r\n\r\n".utf8))
        let raw = text(await read(client) { self.text($0).hasSuffix("0\r\n\r\n") })
        XCTAssertTrue(raw.contains("Transfer-Encoding: chunked\r\n"), raw)
        XCTAssertTrue(raw.contains("Connection: close\r\n"))
        XCTAssertTrue(raw.contains("8\r\n{\"n\":1}\n\r\n8\r\n{\"n\":2}\n\r\n8\r\n{\"n\":3}\n\r\n0\r\n\r\n"), raw)
    }

    func testHijackUpgradesAndCarriesRawBytesBothWays() async throws {
        let client = try connect()
        defer { client.close() }
        // Bytes sent right behind the request belong to the raw stream.
        try await client.write(Data("POST /attach HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nearly".utf8))
        let head = text(await read(client) { self.text($0).hasSuffix("early") })
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101 UPGRADED\r\n"), head)
        XCTAssertTrue(head.contains("Upgrade: tcp\r\n"))
        XCTAssertTrue(head.contains("Content-Type: application/vnd.docker.raw-stream\r\n"))
        XCTAssertFalse(head.contains("Content-Length"), "no framing on a hijacked stream")

        try await client.write(Data("ping".utf8))
        let echoed = text(await read(client) { self.text($0) == "ping" })
        XCTAssertEqual(echoed, "ping")

        // Half-close: the handler sees EOF on input, answers and closes.
        client.closeWrite()
        let tail = text(await read(client) { self.text($0) == "bye" })
        XCTAssertEqual(tail, "bye")
    }

    func testHijackWithoutUpgradeAnswers200() async throws {
        let client = try connect()
        defer { client.close() }
        try await client.write(Data("POST /attach HTTP/1.1\r\n\r\n".utf8))
        let head = text(await read(client) { self.text($0).hasSuffix("\r\n\r\n") })
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"), head)
    }

    func testRefusesASocketALiveServerOwns() throws {
        let second = DockerAPIServer(socketPath: path, router: DockerRouter())
        XCTAssertThrowsError(try second.start())
    }

    func testReplacesAStaleSocketFile() async throws {
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        // A dead server's socket file: bind a socket and close it without unlinking.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        var router = DockerRouter()
        router.add("GET", "/_ping") { _ in .text("OK") }
        server = DockerAPIServer(socketPath: path, router: router)
        XCTAssertNoThrow(try server.start())
        let client = try connect()
        defer { client.close() }
        try await client.write(Data("GET /_ping HTTP/1.1\r\n\r\n".utf8))
        let response = text(await read(client) { self.text($0).hasSuffix("OK") })
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    }

    func testLargeResponsesArriveWhole() async throws {
        for (path, expected) in [("/bigdata", 8 << 20), ("/big", 40 * (256 << 10))] {
            let client = try connect()
            defer { client.close() }
            try await client.write(Data("GET \(path) HTTP/1.1\r\n\r\n".utf8))
            // Read until the server closes or the payload is complete.
            var received = Data()
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, let chunk = await client.reader.next() {
                received.append(chunk)
                if path == "/bigdata", received.count >= expected + 100 { break }
            }
            let headEnd = try XCTUnwrap(received.firstRange(of: Data("\r\n\r\n".utf8)))
            let body = received[headEnd.upperBound...]
            if path == "/bigdata" {
                XCTAssertEqual(body.count, expected, path)
            } else {
                // Chunk framing adds a little; the payload alone must be there.
                XCTAssertGreaterThanOrEqual(body.count, expected, path)
                XCTAssertTrue(body.suffix(5) == Data("0\r\n\r\n".utf8), "terminating chunk")
            }
        }
    }
}
