import Foundation

/// Streams the lines of a log file handle (as returned by the apiserver's
/// `containerLogs`): the existing content first, then — when following — new
/// lines as the file grows. Growth is observed with a vnode dispatch source
/// rather than polling; a file truncated by a container restart is read again
/// from the start. Ends when the consumer stops iterating. Memory stays
/// bounded: a long log is read from its last `tailLimit` bytes, in chunks.
enum LogFileStream {
    /// How much of an existing log is read when the stream opens.
    static let tailLimit: UInt64 = 8 << 20
    static let chunkSize = 1 << 20

    static func lines(of handle: FileHandle, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let reader = Reader(handle: handle, continuation: continuation)
            reader.readAvailable()
            guard follow else {
                reader.flush()
                continuation.finish()
                return
            }
            reader.watch()
            continuation.onTermination = { _ in reader.stop() }
        }
    }

    private final class Reader: @unchecked Sendable {
        private let handle: FileHandle
        private let continuation: AsyncThrowingStream<String, Error>.Continuation
        private let queue = DispatchQueue(label: "irekobox.logs")
        private let buffer = LineSplitter()
        private var offset: UInt64 = 0
        private var source: DispatchSourceFileSystemObject?

        init(handle: FileHandle, continuation: AsyncThrowingStream<String, Error>.Continuation) {
            self.handle = handle
            self.continuation = continuation
        }

        func watch() {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: handle.fileDescriptor,
                eventMask: [.extend, .write, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.readAvailable() }
            self.source = source
            source.resume()
        }

        /// Async: `onTermination` may run on `queue` itself (a finish from the
        /// event handler), where a sync hop would deadlock.
        func stop() {
            queue.async { [self] in
                source?.cancel()
                source = nil
            }
        }

        /// Read everything past `offset`, restarting from 0 if the file shrank;
        /// from a long log only its tail, starting at the first whole line.
        func readAvailable() {
            do {
                let size = try handle.seekToEnd()
                if size < offset { offset = 0; buffer.reset() }
                if size - offset > LogFileStream.tailLimit {
                    offset = size - LogFileStream.tailLimit
                    buffer.reset()
                    buffer.skipPartialLine()
                }
                guard size > offset else { return }
                try handle.seek(toOffset: offset)
                while offset < size {
                    let data = handle.readData(ofLength: min(LogFileStream.chunkSize, Int(size - offset)))
                    guard !data.isEmpty else { break }
                    offset += UInt64(data.count)
                    for line in buffer.append(data) {
                        continuation.yield(line)
                    }
                }
            } catch {
                continuation.finish(throwing: EngineError.decoding("log read failed: \(error.localizedDescription)"))
                source?.cancel()
            }
        }

        func flush() {
            if let tail = buffer.flush() { continuation.yield(tail) }
        }
    }
}

/// Splits byte chunks into newline-terminated UTF-8 lines. A line longer
/// than `maxLine` comes out in pieces rather than growing without bound.
final class LineSplitter: @unchecked Sendable {
    static let maxLine = 64 << 10
    private var data = Data()
    private var dropping = false

    /// Drop everything up to the next newline: reading starts mid-line.
    func skipPartialLine() { dropping = true }

    func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        if dropping {
            guard let newline = data.firstIndex(of: 0x0A) else { data.removeAll(); return [] }
            data.removeSubrange(data.startIndex...newline)
            dropping = false
        }
        var lines: [String] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[start..<newline], as: UTF8.self))
            start = data.index(after: newline)
        }
        data.removeSubrange(data.startIndex..<start)
        while data.count > Self.maxLine {
            lines.append(String(decoding: data.prefix(Self.maxLine), as: UTF8.self))
            data.removeFirst(Self.maxLine)
        }
        return lines
    }

    func flush() -> String? {
        defer { data.removeAll() }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func reset() { data.removeAll(); dropping = false }
}
