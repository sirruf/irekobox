import Foundation

/// A small HTTP/1.1 client for a Docker API on a Unix socket: one request
/// per connection (`Connection: close`), JSON in and out. Enough to read
/// Docker Desktop and to create things through Irekobox's socket.
public struct UnixHTTP: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public struct Response: Sendable {
        public let status: Int
        public let body: Data

        public var ok: Bool { (200..<300).contains(status) }

        /// Docker's `{"message": …}`, else the body as text.
        public var message: String {
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let message = object["message"] as? String {
                return message
            }
            return String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public enum Failure: Error, LocalizedError {
        case connect(String, Int32)
        case io(Int32)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .connect(let path, let code): return String(localized: "Can't connect to \(path): \(String(cString: strerror(code)))")
            case .io(let code): return String(localized: "Socket error: \(String(cString: strerror(code)))")
            case .malformed: return String(localized: "Malformed HTTP response")
            }
        }
    }

    public func get(_ path: String, timeout: TimeInterval = 30) async throws -> Response {
        try await request("GET", path, timeout: timeout)
    }

    public func post(_ path: String, json: Any? = nil, timeout: TimeInterval = 120) async throws -> Response {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await request("POST", path, body: body, timeout: timeout)
    }

    public func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) async throws -> Response {
        let socketPath = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try Self.send(method, path, body: body, socketPath: socketPath, timeout: timeout)
                })
            }
        }
    }

    // MARK: - Blocking I/O

    static func send(_ method: String, _ path: String, body: Data?, socketPath: String, timeout: TimeInterval) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io(errno) }
        defer { close(fd) }
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.connect(socketPath, ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.connect(socketPath, errno) }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nUser-Agent: Irekobox\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        try write(fd, Data(head.utf8) + (body ?? Data()))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw Failure.io(errno) }
            if count == 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return try parse(received)
    }

    private static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { throw Failure.io(errno) }
                offset += written
            }
        }
    }

    /// Status line, headers, then a Content-Length, chunked or read-to-close body.
    static func parse(_ data: Data) throws -> Response {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.malformed }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[split.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try dechunk(body)
        } else if let length = headers["content-length"].flatMap(Int.init), body.count > length {
            body = body.prefix(length)
        }
        return Response(status: status, body: body)
    }

    static func dechunk(_ data: Data) throws -> Data {
        var result = Data()
        var index = data.startIndex
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { throw Failure.malformed }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw Failure.malformed }
            if size == 0 { break }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size else { throw Failure.malformed }
            let end = data.index(start, offsetBy: size)
            result.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return result
    }
}
