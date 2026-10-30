import Foundation
import Darwin

/// A listening Unix domain socket. Accepted connections are handed to
/// `onConnection`; the socket file is created mode 0600 (only this user).
final class UnixSocketListener: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let source: DispatchSourceRead

    enum ListenError: Error, Equatable {
        case pathTooLong(String)
        case inUse(String)
        case system(String, Int32)
    }

    init(path: String, onConnection: @escaping @Sendable (SocketConnection) -> Void) throws {
        self.path = path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw ListenError.pathTooLong(path) }
        try Self.removeStaleSocket(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenError.system("socket", errno) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ListenError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            throw ListenError.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "docker-api.accept"))
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }   // EAGAIN: drained
                onConnection(SocketConnection(fd: client))
            }
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source.cancel()
    }

    /// A socket file left by a crashed run is removed; one that still accepts
    /// connections belongs to a live server and is not touched.
    private static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw ListenError.inUse(path) }
        if SocketConnection.connect(to: path) != nil { throw ListenError.inUse(path) }
        unlink(path)
    }
}

/// One accepted (or dialed) stream socket. Reads arrive through `reader`;
/// writes run on a private serial queue, so a slow client never blocks the
/// Swift concurrency pool.
final class SocketConnection: HijackedConnection, @unchecked Sendable {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "docker-api.write")
    private let readSource: DispatchSourceRead
    /// Left when the read source is cancelled: the fd may be closed after that.
    private let readDone = DispatchGroup()
    let reader: ByteReader
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Accepted sockets inherit O_NONBLOCK from the listener; writes here
        // are blocking by design (on a private queue), and reads only follow
        // readability events. Non-blocking, a large response hit EAGAIN once
        // the send buffer filled and was cut off.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        reader = ByteReader(stream)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "docker-api.read"))
        readSource = source
        readDone.enter()
        source.setEventHandler { [weak source] in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                continuation.yield(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EOF (or the client half-closed): no more input, but we may
                // still be writing to it.
                source?.cancel()
            }
        }
        source.setCancelHandler { [readDone] in
            continuation.finish()
            readDone.leave()
        }
        source.resume()
    }

    /// Client bytes from the start (HTTP); after a hijack, the raw stream.
    var input: AsyncStream<Data> { reader.remaining() }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [fd] in
                var offset = 0
                while offset < data.count {
                    let written = data.withUnsafeBytes { bytes in
                        Darwin.write(fd, bytes.baseAddress! + offset, data.count - offset)
                    }
                    if written < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                        return
                    }
                    offset += written
                }
                continuation.resume()
            }
        }
    }

    func closeWrite() {
        writeQueue.async { [fd] in _ = shutdown(fd, SHUT_WR) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // After queued writes: the fd stays valid until the last one ran.
        writeQueue.async { [fd, readSource, readDone] in
            readSource.cancel()
            readDone.wait()
            Darwin.close(fd)
        }
    }

    /// Connect to a Unix socket (tests, and the stale-socket probe).
    static func connect(to path: String) -> SocketConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes {
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1)))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return SocketConnection(fd: fd)
    }
}

/// The single consumer of a connection's bytes, shared by the HTTP loop and,
/// after a hijack, the raw stream (an AsyncStream can't be iterated twice).
final class ByteReader: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.Iterator
    private var pushedBack = Data()
    private let lock = NSLock()

    init(_ stream: AsyncStream<Data>) {
        iterator = stream.makeAsyncIterator()
    }

    /// The next bytes, or nil at end of stream. Only one caller at a time.
    func next() async -> Data? {
        let early: Data? = lock.withLock {
            guard !pushedBack.isEmpty else { return nil }
            defer { pushedBack = Data() }
            return pushedBack
        }
        if let early { return early }
        var iterator = lock.withLock { self.iterator }
        let value = await iterator.next()
        lock.withLock { self.iterator = iterator }
        return value
    }

    /// Bytes the parser read past the request, returned first.
    func pushBack(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { pushedBack = data + pushedBack }
    }

    /// Everything from here on as a stream (for a hijacked connection).
    func remaining() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                while let data = await self.next() { continuation.yield(data) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
