import Foundation

/// Incremental HTTP/1.1 request parser. Feed bytes as they arrive and take
/// complete requests one at a time; bytes after a request stay buffered (the
/// next pipelined request, or raw stream data once a connection is hijacked).
///
/// Bodies are consumed as they arrive, so a large upload costs linear time and
/// little memory: past `memoryLimit` a body goes to a temporary file
/// (`HTTPRequest.bodyFile`), which the caller deletes when done with it.
public struct HTTPParser: Sendable {
    public enum ParseError: Error, Equatable {
        /// 400: malformed request line, header or chunk framing.
        case badRequest(String)
        /// 431: the head (or chunked trailer) is larger than `maxHeadSize`.
        case headTooLarge
        /// 413: the body is larger than `maxBodySize`.
        case bodyTooLarge
        /// 501: a transfer coding other than chunked.
        case unsupportedTransferEncoding(String)

        public var status: Int {
            switch self {
            case .badRequest: return 400
            case .headTooLarge: return 431
            case .bodyTooLarge: return 413
            case .unsupportedTransferEncoding: return 501
            }
        }
    }

    public var maxHeadSize: Int
    public var maxBodySize: Int
    /// Bodies larger than this are written to a temporary file.
    public var memoryLimit: Int
    private var storage = Data()
    private var offset = 0
    private var buffer: Data { storage[offset...] }
    /// A request whose body is still arriving.
    private var pending: Pending?

    private struct Pending: Sendable {
        var request: HTTPRequest
        var body: BodySink
        enum Framing: Sendable {
            /// Content-Length: bytes still to come.
            case length(Int)
            /// Expecting a chunk size line.
            case chunkSize
            /// Inside a chunk: bytes still to come, then its CRLF.
            case chunkData(Int)
            /// Past the last chunk, reading trailer fields; their bytes so far.
            case trailer(Int)
        }
        var framing: Framing
    }

    public init(maxHeadSize: Int = 64 << 10, maxBodySize: Int = 64 << 30, memoryLimit: Int = 16 << 20) {
        self.maxHeadSize = maxHeadSize
        self.maxBodySize = maxBodySize
        self.memoryLimit = memoryLimit
    }

    public mutating func feed(_ data: Data) {
        // Compact only after a substantial prefix is consumed. Pipelined
        // requests and chunks otherwise just advance the offset.
        if offset >= 64 << 10, offset >= storage.count / 2 {
            storage = Data(buffer)
            offset = 0
        }
        storage.append(data)
    }

    /// Bytes received but not consumed by a request — handed to the raw
    /// stream after a hijack.
    public mutating func takeRemaining() -> Data {
        let remaining = Data(buffer)
        storage = Data()
        offset = 0
        return remaining
    }

    /// The next complete request, or nil when more bytes are needed.
    public mutating func next() throws -> HTTPRequest? {
        if pending == nil {
            guard let started = try startRequest() else { return nil }
            pending = started
        }
        do {
            let request = try continueBody()
            if request != nil { pending = nil }
            return request
        } catch {
            pending?.body.discard()
            pending = nil
            throw error
        }
    }

    // MARK: - Head

    private mutating func startRequest() throws -> Pending? {
        // Tolerate stray CRLFs between requests (RFC 9112 §2.2).
        while buffer.starts(with: [0x0D, 0x0A]) { consume(count: 2) }

        guard let headEnd = buffer.firstRange(of: Self.crlfcrlf) else {
            if buffer.count > maxHeadSize { throw ParseError.headTooLarge }
            return nil
        }
        let headLength = headEnd.lowerBound - buffer.startIndex
        if headLength > maxHeadSize { throw ParseError.headTooLarge }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.badRequest("request head is not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") || requestLine[1] == "*",
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            throw ParseError.badRequest("malformed request line")
        }
        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line[..<colon].contains(" ") else {
                throw ParseError.badRequest("malformed header line")
            }
            headers.append((String(line[..<colon]),
                            line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                  version: String(requestLine[2]), headers: headers)

        let framing: Pending.Framing
        if let coding = request.header("Transfer-Encoding") {
            guard coding.lowercased() == "chunked" else { throw ParseError.unsupportedTransferEncoding(coding) }
            framing = .chunkSize
        } else if let value = request.header("Content-Length") {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(value) else {
                throw ParseError.badRequest("bad Content-Length")
            }
            if length > maxBodySize { throw ParseError.bodyTooLarge }
            framing = .length(length)
        } else {
            framing = .length(0)
        }
        consume(upTo: headEnd.upperBound)
        return Pending(request: request, body: BodySink(memoryLimit: memoryLimit), framing: framing)
    }

    // MARK: - Body

    /// Move whatever body bytes have arrived into the sink; the request once
    /// its body is complete.
    private mutating func continueBody() throws -> HTTPRequest? {
        guard var state = pending else { return nil }
        defer { pending = state }
        while true {
            switch state.framing {
            case .length(let left):
                let take = min(left, buffer.count)
                if take > 0 {
                    try state.body.append(buffer.prefix(take))
                    consume(count: take)
                }
                guard left == take else {
                    state.framing = .length(left - take)
                    return nil
                }
                return try finish(&state)

            case .chunkSize:
                guard let lineEnd = buffer.firstRange(of: Self.crlf) else {
                    if buffer.count > 1024 { throw ParseError.badRequest("chunk size line too long") }
                    return nil
                }
                let sizeLine = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? ""
                guard !sizeText.isEmpty, sizeText.count <= 16, sizeText.allSatisfy(\.isHexDigit),
                      let size = Int(sizeText, radix: 16) else {
                    throw ParseError.badRequest("bad chunk size")
                }
                // Compared without adding, so a huge size can't overflow.
                if size > maxBodySize - state.body.count { throw ParseError.bodyTooLarge }
                consume(upTo: lineEnd.upperBound)
                state.framing = size == 0 ? .trailer(0) : .chunkData(size)

            case .chunkData(let left):
                if left > 0 {
                    let take = min(left, buffer.count)
                    guard take > 0 else { return nil }
                    try state.body.append(buffer.prefix(take))
                    consume(count: take)
                    state.framing = .chunkData(left - take)
                    if take < left { return nil }
                }
                guard buffer.count >= 2 else { return nil }
                guard buffer[buffer.startIndex] == 0x0D, buffer[buffer.startIndex + 1] == 0x0A else {
                    throw ParseError.badRequest("chunk not terminated by CRLF")
                }
                consume(count: 2)
                state.framing = .chunkSize

            case .trailer(let read):
                // Optional trailer fields, then an empty line; bounded like a head.
                guard let lineEnd = buffer.firstRange(of: Self.crlf) else {
                    if read + buffer.count > maxHeadSize { throw ParseError.headTooLarge }
                    return nil
                }
                let isEmpty = lineEnd.lowerBound == buffer.startIndex
                let length = lineEnd.upperBound - buffer.startIndex
                consume(count: length)
                if isEmpty { return try finish(&state) }
                state.framing = .trailer(read + length)
            }
        }
    }

    private func finish(_ state: inout Pending) throws -> HTTPRequest {
        var request = state.request
        (request.body, request.bodyFile) = try state.body.finish()
        return request
    }

    /// Advance without copying the unread bytes after each chunk or request.
    private mutating func consume(count: Int) {
        offset += count
        if offset == storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        }
    }

    private mutating func consume(upTo index: Data.Index) {
        consume(count: index - buffer.startIndex)
    }

    private static let crlf = Data([0x0D, 0x0A])
    private static let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
}

/// A request body as it arrives: in memory up to a limit, then in a
/// temporary file (mode 0600 in a 0700 folder).
final class BodySink: @unchecked Sendable {
    private let memoryLimit: Int
    private var data = Data()
    private var file: FileHandle?
    private var url: URL?
    private(set) var count = 0

    init(memoryLimit: Int) {
        self.memoryLimit = memoryLimit
    }

    func append(_ chunk: Data) throws {
        count += chunk.count
        if file == nil, data.count + chunk.count <= memoryLimit {
            data.append(chunk)
            return
        }
        if file == nil {
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "irekobox-body-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = folder.appending(path: "body")
            guard FileManager.default.createFile(atPath: url.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            file = try FileHandle(forWritingTo: url)
            try file?.seekToEnd()
            self.url = url
            data = Data()
        }
        try file?.write(contentsOf: chunk)
    }

    /// The body in memory, or the file holding it.
    func finish() throws -> (Data, URL?) {
        try file?.close()
        file = nil
        return (data, url)
    }

    /// Delete a partly written file after a failed request.
    func discard() {
        try? file?.close()
        file = nil
        if let url { HTTPRequest.removeBodyFile(url) }
    }
}
