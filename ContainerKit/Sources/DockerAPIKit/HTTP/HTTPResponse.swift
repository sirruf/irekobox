import Foundation

/// What a handler answers. The server frames it on the wire.
public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// Sent with `Transfer-Encoding: chunked`, one chunk per element, as
        /// they come (logs, stats, events, progress).
        case stream(AsyncThrowingStream<Data, Error>)
        /// Take over the connection after the head (`101` for `Upgrade: tcp`
        /// clients, `200` otherwise): attach and exec.
        case hijack(@Sendable (HijackedConnection) async -> Void)
    }

    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Body

    public init(status: Int, headers: [(name: String, value: String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// JSON with Docker's encoding conventions (keys as declared by the model).
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")],
                            body: .data(data + Data("\n".utf8)))
    }

    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")],
                     body: .data(Data(text.utf8)))
    }

    /// Docker's error shape: `{"message": "..."}`.
    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["message": message], status: status)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 101: return "UPGRADED"
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status \(status)"
        }
    }
}

/// The raw duplex stream of a hijacked connection.
public protocol HijackedConnection: Sendable {
    /// Bytes from the client; ends when the client closes or half-closes.
    var input: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    /// Close our sending side (the client sees EOF on its read).
    func closeWrite()
}
