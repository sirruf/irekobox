import Foundation
@preconcurrency import XPC

/// Minimal client for the `container-apiserver` XPC API (system `libxpc` only).
///
/// Protocol (mirrored from apple/container `Sources/ContainerXPC` and
/// `ContainerAPIService/Client/XPC+.swift`, Apache-2.0): a request is a
/// dictionary whose `com.apple.container.xpc.route` names the operation, with
/// arguments under named keys (JSON payloads as data); a reply carries results
/// under named keys, or a JSON `{code, message}` under
/// `com.apple.container.xpc.error`. The apiserver API is compatible within a
/// major `container` version.
final class APIServerConnection: @unchecked Sendable {
    static let serviceName = "com.apple.container.apiserver"
    static let routeKey = "com.apple.container.xpc.route"
    static let errorKey = "com.apple.container.xpc.error"

    private let serviceName: String
    private let queue = DispatchQueue(label: "irekobox.apiserver")
    private let lock = NSLock()
    private var connection: xpc_connection_t?

    init(serviceName: String = APIServerConnection.serviceName) {
        self.serviceName = serviceName
    }

    deinit {
        if let connection { xpc_connection_cancel(connection) }
    }

    /// A request under construction.
    struct Request {
        let object: xpc_object_t = xpc_dictionary_create_empty()

        init(route: String) {
            xpc_dictionary_set_string(object, APIServerConnection.routeKey, route)
        }

        func set(_ key: String, _ value: String) { xpc_dictionary_set_string(object, key, value) }
        func set(_ key: String, _ value: Bool) { xpc_dictionary_set_bool(object, key, value) }
        func set(_ key: String, _ value: UInt64) { xpc_dictionary_set_uint64(object, key, value) }
        /// A file descriptor: XPC sends a duplicate, the caller keeps its own.
        func set(_ key: String, fileDescriptor: Int32) { xpc_dictionary_set_fd(object, key, fileDescriptor) }
        func set(_ key: String, _ value: Data) {
            value.withUnsafeBytes { buffer in
                xpc_dictionary_set_data(object, key, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, value.count)
            }
        }
    }

    /// A successful reply.
    struct Reply: @unchecked Sendable {
        let object: xpc_object_t

        func data(_ key: String) -> Data? {
            var length = 0
            guard let bytes = xpc_dictionary_get_data(object, key, &length) else { return nil }
            return Data(bytes: bytes, count: length)
        }

        func uint64(_ key: String) -> UInt64 { xpc_dictionary_get_uint64(object, key) }
        func int64(_ key: String) -> Int64 { xpc_dictionary_get_int64(object, key) }
        /// An XPC date (nanoseconds since 1970).
        func date(_ key: String) -> Date? {
            guard let value = xpc_dictionary_get_value(object, key), xpc_get_type(value) == XPC_TYPE_DATE else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(xpc_date_get_value(value)) / 1_000_000_000)
        }
        func has(_ key: String) -> Bool { xpc_dictionary_get_value(object, key) != nil }

        /// File descriptors sent as an XPC array, duplicated and owned by the caller.
        func fileHandles(_ key: String) -> [FileHandle] {
            guard let array = xpc_dictionary_get_value(object, key),
                  xpc_get_type(array) == XPC_TYPE_ARRAY else { return [] }
            return (0..<xpc_array_get_count(array)).compactMap { index in
                let fd = xpc_array_dup_fd(array, index)
                return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
            }
        }
    }

    /// Send `request` and await the reply. Throws ``EngineError``:
    /// `.servicesNotRunning` when the apiserver is unreachable, `.timedOut`,
    /// `.cancelled`, or the server's error mapped by ``EngineError/fromServer(code:message:)``.
    func send(_ request: Request, timeout: Duration? = .seconds(30)) async throws -> Reply {
        let connection = currentConnection()
        let pending = PendingReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                xpc_connection_send_message_with_reply(connection, request.object, queue) { reply in
                    pending.resume(with: self.parse(reply, from: connection))
                }
                if let timeout {
                    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.nanoseconds))) {
                        pending.resume(with: .failure(EngineError.timedOut))
                    }
                }
            }
        } onCancel: {
            pending.resume(with: .failure(EngineError.cancelled))
        }
    }

    // MARK: - Private

    private func currentConnection() -> xpc_connection_t {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let connection = xpc_connection_create_mach_service(serviceName, queue, 0)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            // An invalidated connection can't be reused (e.g. the apiserver was
            // stopped); drop it so the next request reconnects.
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.drop(connection)
            }
        }
        xpc_connection_activate(connection)
        self.connection = connection
        return connection
    }

    private func drop(_ stale: xpc_connection_t) {
        lock.lock(); defer { lock.unlock() }
        if let connection, connection === stale {
            self.connection = nil
        }
    }

    private func parse(_ reply: xpc_object_t, from connection: xpc_connection_t) -> Result<Reply, Error> {
        let type = xpc_get_type(reply)
        if type == XPC_TYPE_ERROR {
            drop(connection)
            return .failure(EngineError.servicesNotRunning)
        }
        guard type == XPC_TYPE_DICTIONARY else {
            return .failure(EngineError.decoding("unexpected XPC reply type"))
        }
        let message = Reply(object: reply)
        if let payload = message.data(Self.errorKey) {
            struct ServerError: Decodable { let code: String; let message: String }
            guard let error = try? JSONDecoder().decode(ServerError.self, from: payload) else {
                return .failure(EngineError.decoding("malformed apiserver error"))
            }
            return .failure(EngineError.fromServer(code: error.code, message: error.message))
        }
        return .success(message)
    }
}

extension EngineError {
    /// Map an apiserver error (`ContainerizationError.Code` name + message).
    static func fromServer(code: String, message: String) -> EngineError {
        switch code {
        case "notFound": return .notFound(message)
        case "exists": return .conflict(message)
        case "cancelled": return .cancelled
        case "timeout": return .timedOut
        default: return .serviceError(code: code, message: message)
        }
    }
}

/// Resumes a continuation exactly once — with the reply, a timeout, or a
/// cancellation, whichever comes first. Late outcomes are dropped.
private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<APIServerConnection.Reply, Error>?
    private var early: Result<APIServerConnection.Reply, Error>?
    private var done = false

    func install(_ continuation: CheckedContinuation<APIServerConnection.Reply, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<APIServerConnection.Reply, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        guard let continuation else {
            // Cancelled before the continuation was installed.
            early = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

extension Duration {
    var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
