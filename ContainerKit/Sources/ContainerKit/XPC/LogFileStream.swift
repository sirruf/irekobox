import Foundation

/// Streams the lines of a log file handle (as returned by the apiserver's
/// `containerLogs`): the existing content first, then — when following — new
/// lines as the file grows. Growth is observed with a vnode dispatch source
/// rather than polling; a file truncated by a container restart is read again
/// from the start. Ends when the consumer stops iterating.
enum LogFileStream {
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

        /// Read everything past `offset`, restarting from 0 if the file shrank.
        func readAvailable() {
            do {
                let size = try handle.seekToEnd()
                if size < offset { offset = 0; buffer.reset() }
                guard size > offset else { return }
                try handle.seek(toOffset: offset)
                let data = handle.readData(ofLength: Int(size - offset))
                offset += UInt64(data.count)
                for line in buffer.append(data) {
                    continuation.yield(line)
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

/// Splits byte chunks into newline-terminated UTF-8 lines.
final class LineSplitter: @unchecked Sendable {
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }

    func flush() -> String? {
        defer { data.removeAll() }
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func reset() { data.removeAll() }
}
