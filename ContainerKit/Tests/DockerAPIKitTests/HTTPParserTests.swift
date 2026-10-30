import XCTest
@testable import DockerAPIKit

final class HTTPParserTests: XCTestCase {

    private func parse(_ chunks: [String], parser: inout HTTPParser) throws -> [HTTPRequest] {
        var requests: [HTTPRequest] = []
        for chunk in chunks {
            parser.feed(Data(chunk.utf8))
            while let request = try parser.next() { requests.append(request) }
        }
        return requests
    }

    func testSimpleGetWithQuery() throws {
        var parser = HTTPParser()
        let requests = try parse(["GET /v1.45/containers/json?all=1&filters=%7B%22label%22%3A%5B%5D%7D HTTP/1.1\r\nHost: docker\r\nUser-Agent: Docker-Client/29.9.2\r\n\r\n"], parser: &parser)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1.45/containers/json")
        XCTAssertEqual(request.query["all"], "1")
        XCTAssertEqual(request.query["filters"], #"{"label":[]}"#)
        XCTAssertEqual(request.header("user-agent"), "Docker-Client/29.9.2")
        XCTAssertTrue(request.keepAlive)
        XCTAssertTrue(request.body.isEmpty)
    }

    func testBodyArrivingInPieces() throws {
        var parser = HTTPParser()
        let pieces = ["POST /containers/create HTTP/1.1\r\nContent-Le", "ngth: 15\r\n\r\n{\"Image\":", "\"alp\"}"]
        var requests = try parse(Array(pieces.prefix(2)), parser: &parser)
        XCTAssertTrue(requests.isEmpty, "incomplete body")
        requests = try parse([pieces[2]], parser: &parser)
        XCTAssertEqual(requests.first?.body, Data(#"{"Image":"alp"}"#.utf8))
    }

    func testChunkedBodyWithExtensionsAndTrailers() throws {
        var parser = HTTPParser()
        let raw = "PUT /containers/x/archive?path=/tmp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5;name=value\r\nhello\r\n" + "6\r\n world\r\n" + "0\r\nX-Checksum: abc\r\n\r\n"
        // Feed byte by byte: every split point must work.
        var requests: [HTTPRequest] = []
        for byte in raw.utf8 {
            parser.feed(Data([byte]))
            while let request = try parser.next() { requests.append(request) }
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.body, Data("hello world".utf8))
    }

    func testChunkedRequestFollowedByAnother() throws {
        var parser = HTTPParser()
        let raw = "POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
            + "GET /b HTTP/1.1\r\n\r\n"
        var requests: [HTTPRequest] = []
        for piece in [raw.prefix(40), raw.dropFirst(40)] {
            parser.feed(Data(piece.utf8))
            while let request = try parser.next() { requests.append(request) }
        }
        XCTAssertEqual(requests.map(\.path), ["/a", "/b"])
        XCTAssertEqual(requests.first?.body, Data("abc".utf8))
    }

    func testLargeChunkedUploadIsDecodedOnce() throws {
        var parser = HTTPParser()
        parser.feed(Data("PUT /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        let chunk = Data("1000\r\n".utf8) + Data(repeating: 0x61, count: 0x1000) + Data("\r\n".utf8)
        for _ in 0..<2048 {
            parser.feed(chunk)
            XCTAssertNil(try parser.next())
        }
        parser.feed(Data("0\r\n\r\n".utf8))
        XCTAssertEqual(try parser.next()?.body.count, 2048 * 0x1000)
    }

    func testLargeBodyGoesToAFileAndArrivesWhole() throws {
        for framing in ["Content-Length: 3000", "Transfer-Encoding: chunked"] {
            var parser = HTTPParser(memoryLimit: 1000)
            parser.feed(Data("POST /images/load HTTP/1.1\r\n\(framing)\r\n\r\n".utf8))
            let payload = Data((0..<3000).map { UInt8($0 % 251) })
            var request: HTTPRequest?
            for start in stride(from: 0, to: payload.count, by: 700) {
                let piece = payload[start..<min(start + 700, payload.count)]
                parser.feed(framing.hasPrefix("Transfer") ? Data(String(piece.count, radix: 16).utf8) + Data("\r\n".utf8) + piece + Data("\r\n".utf8) : piece)
                request = try parser.next() ?? request
            }
            if framing.hasPrefix("Transfer") {
                parser.feed(Data("0\r\n\r\n".utf8))
                request = try parser.next()
            }
            let file = try XCTUnwrap(request?.bodyFile, framing)
            XCTAssertTrue(request?.body.isEmpty ?? false)
            XCTAssertEqual(try Data(contentsOf: file), payload, framing)
            HTTPRequest.removeBodyFile(file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testPipelinedRequestsAndLeftoverBytes() throws {
        var parser = HTTPParser()
        let raw = "GET /_ping HTTP/1.1\r\n\r\nGET /version HTTP/1.1\r\n\r\n"
            + "POST /containers/x/attach?stream=1 HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nraw stdin bytes"
        let requests = try parse([raw], parser: &parser)
        XCTAssertEqual(requests.map(\.path), ["/_ping", "/version", "/containers/x/attach"])
        XCTAssertTrue(requests[2].wantsUpgrade)
        XCTAssertEqual(parser.takeRemaining(), Data("raw stdin bytes".utf8), "bytes after a hijack request")
    }

    func testConnectionPersistence() throws {
        var parser = HTTPParser()
        let requests = try parse(["GET / HTTP/1.0\r\n\r\n", "GET / HTTP/1.1\r\nConnection: close\r\n\r\n",
                                  "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"], parser: &parser)
        XCTAssertEqual(requests.map(\.keepAlive), [false, false, true])
    }

    func testRejectsMalformedInput() {
        func error(_ raw: String, limit: Int = 64 << 10) -> HTTPParser.ParseError? {
            var parser = HTTPParser(maxHeadSize: limit, maxBodySize: 10)
            parser.feed(Data(raw.utf8))
            do { _ = try parser.next(); return nil } catch { return error as? HTTPParser.ParseError }
        }
        XCTAssertEqual(error("GARBAGE\r\n\r\n")?.status, 400)
        XCTAssertEqual(error("GET /x HTTP/2.0\r\n\r\n")?.status, 400)
        XCTAssertEqual(error("GET /x HTTP/1.1\r\nBad Header\r\n\r\n")?.status, 400)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n")?.status, 400)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nContent-Length: 11\r\n\r\n")?.status, 413)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n")?.status, 501)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")?.status, 400)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXY")?.status, 400)
        XCTAssertEqual(error("GET /" + String(repeating: "a", count: 100) + " HTTP/1.1\r\n", limit: 32)?.status, 431)
        // A chunk size near Int.max must be refused, not overflow.
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffffffffffff\r\n")?.status, 413)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n+5\r\n")?.status, 400)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nContent-Length: +5\r\n\r\n")?.status, 400)
        XCTAssertEqual(error("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
                             + String(repeating: "X-T: y\r\n", count: 20), limit: 64)?.status, 431)
    }
}
