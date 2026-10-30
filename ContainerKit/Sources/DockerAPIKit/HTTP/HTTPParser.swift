import Foundation

/// Incremental HTTP/1.1 request parser. Feed bytes as they arrive and take
/// complete requests one at a time; bytes after a request stay buffered (the
/// next pipelined request, or raw stream data once a connection is hijacked).
public struct HTTPParser: Sendable {
    public enum ParseError: Error, Equatable {
        /// 400: malformed request line, header or chunk framing.
        case badRequest(String)
        /// 431: the head is larger than `maxHeadSize`.
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
    private var buffer = Data()
    /// A chunked request whose body is still arriving: decoding resumes
    /// where it stopped, so a large upload costs linear time.
    private var pending: Pending?

    private struct Pending: Sendable {
        var request: HTTPRequest
        var body = Data()
        /// Where decoding resumes in `buffer`.
        var index: Data.Index
        /// Past the last chunk, reading trailer fields; their bytes so far.
        var trailerBytes: Int?
    }

    public init(maxHeadSize: Int = 64 << 10, maxBodySize: Int = 256 << 20) {
        self.maxHeadSize = maxHeadSize
        self.maxBodySize = maxBodySize
    }

    public mutating func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Bytes received but not consumed by a request — handed to the raw
    /// stream after a hijack.
    public mutating func takeRemaining() -> Data {
        defer { buffer = Data() }
        return buffer
    }

    /// The next complete request, or nil when more bytes are needed.
    public mutating func next() throws -> HTTPRequest? {
        if pending != nil { return try finishChunked() }
        // Tolerate stray CRLFs between requests (RFC 9112 §2.2).
        while buffer.starts(with: [0x0D, 0x0A]) { buffer.removeFirst(2) }

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
        var request = HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                  version: String(requestLine[2]), headers: headers)
        let bodyStart = headEnd.upperBound

        if let coding = request.header("Transfer-Encoding") {
            guard coding.lowercased() == "chunked" else { throw ParseError.unsupportedTransferEncoding(coding) }
            pending = Pending(request: request, index: bodyStart)
            return try finishChunked()
        } else {
            let length: Int
            if let value = request.header("Content-Length") {
                guard value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let parsed = Int(value) else {
                    throw ParseError.badRequest("bad Content-Length")
                }
                length = parsed
            } else {
                length = 0
            }
            if length > maxBodySize { throw ParseError.bodyTooLarge }
            guard buffer.endIndex - bodyStart >= length else { return nil }
            request.body = Data(buffer[bodyStart..<(bodyStart + length)])
            buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
        }
        // Keep indices zero-based for the next round.
        buffer = Data(buffer)
        return request
    }

    /// Continue the pending chunked body; the request once it's complete,
    /// nil while more bytes are needed.
    private mutating func finishChunked() throws -> HTTPRequest? {
        guard var state = pending else { return nil }
        // Decoding stops at the buffer's end; the state is kept for the next bytes.
        defer { if pending != nil { pending = state } }
        while true {
            if let read = state.trailerBytes {
                // Optional trailer fields, then an empty line; bounded like a head.
                guard let lineEnd = buffer[state.index...].firstRange(of: Self.crlf) else {
                    if read + (buffer.endIndex - state.index) > maxHeadSize { throw ParseError.headTooLarge }
                    return nil
                }
                let isEmpty = lineEnd.lowerBound == state.index
                state.trailerBytes = read + (lineEnd.upperBound - state.index)
                state.index = lineEnd.upperBound
                guard isEmpty else { continue }
                var request = state.request
                request.body = state.body
                buffer.removeSubrange(buffer.startIndex..<state.index)
                // Keep indices zero-based for the next round.
                buffer = Data(buffer)
                pending = nil
                return request
            }
            guard let lineEnd = buffer[state.index...].firstRange(of: Self.crlf) else {
                if buffer.endIndex - state.index > 1024 { throw ParseError.badRequest("chunk size line too long") }
                return nil
            }
            let sizeLine = String(decoding: buffer[state.index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 16, sizeText.allSatisfy(\.isHexDigit),
                  let size = Int(sizeText, radix: 16) else {
                throw ParseError.badRequest("bad chunk size")
            }
            // Compared without adding, so a huge size can't overflow.
            if size > maxBodySize - state.body.count { throw ParseError.bodyTooLarge }
            if size == 0 {
                state.index = lineEnd.upperBound
                state.trailerBytes = 0
                continue
            }
            let dataStart = lineEnd.upperBound
            guard buffer.endIndex - dataStart >= size + 2 else { return nil }
            let dataEnd = dataStart + size
            guard buffer[dataEnd] == 0x0D, buffer[dataEnd + 1] == 0x0A else {
                throw ParseError.badRequest("chunk not terminated by CRLF")
            }
            state.body.append(buffer[dataStart..<dataEnd])
            state.index = dataEnd + 2
        }
    }

    private static let crlf = Data([0x0D, 0x0A])
    private static let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
}
