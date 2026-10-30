import Foundation
import ContainerKit

/// `GET /containers/{id}/logs` and `/stats`.
///
/// What the runtime gives: one combined output file (stdout and stderr
/// interleaved, no per-line times) and cumulative counters. So logs go out
/// as stdout, timestamps are the time we read a line, and CPU is reported so
/// that Docker's own formula yields percent of one core.
public enum LogsStatsAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend) {
        let directory = ContainerDirectory(backend: backend)
        router.add("GET", "/containers/{id}/logs") { request in
            await respond { try await logs(request, directory, backend) }
        }
        router.add("GET", "/containers/{id}/stats") { request in
            await respond { try await stats(request, directory, backend) }
        }
    }

    // MARK: - Logs

    /// Docker's multiplexed frame: [stream, 0, 0, 0, size (UInt32 BE)] + payload.
    static func frame(_ payload: Data, stream: UInt8 = 1) -> Data {
        var header = Data([stream, 0, 0, 0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.append(contentsOf: $0) }
        return header + payload
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        // RFC 3339 with nanoseconds, as Docker prints them.
        let seconds = date.timeIntervalSince1970
        let whole = Date(timeIntervalSince1970: floor(seconds))
        let base = timestampFormatter.string(from: whole).dropLast()   // drop "Z"
        let nanos = Int((seconds - floor(seconds)) * 1_000_000_000)
        return "\(base).\(String(format: "%09d", nanos))Z"
    }

    static func time(_ value: String?) -> Date? {
        guard let value, !value.isEmpty, value != "0" else { return nil }
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        return DockerTime.parse(value)
    }

    static func logs(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let wantsStdout = request.bool("stdout")
        let wantsStderr = request.bool("stderr")
        guard wantsStdout || wantsStderr else {
            throw DockerAPIError.badParameter("Bad parameters: you must choose at least one stream")
        }
        let item = try await directory.resolve(request.parameters["id"]!)
        let name = item.name
        let tty = item.container.configuration.initProcess.terminal ?? false
        let follow = request.bool("follow")
        let timestamps = request.bool("timestamps")
        let since = time(request.query["since"])
        let until = time(request.query["until"])
        var tail: Int?
        // "all", empty and negative (dockerd and Testcontainers send -1) mean everything.
        if let raw = request.query["tail"], raw != "all", !raw.isEmpty {
            guard let count = Int(raw) else { throw DockerAPIError.badParameter("invalid tail: \(raw)") }
            if count >= 0 { tail = count }
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            // Output isn't split by stream: all of it counts as stdout.
            guard wantsStdout else {
                continuation.finish()
                return
            }
            let emit: @Sendable (String) -> Bool = { line in
                let now = Date()
                if let since, now < since { return true }
                if let until, now > until { return false }
                var text = line + "\n"
                if timestamps { text = "\(timestamp(now)) " + text }
                let payload = Data(text.utf8)
                continuation.yield(tty ? payload : frame(payload))
                return true
            }
            do {
                var historyCount = 0
                var history: [String] = []
                var oldest = 0
                for try await line in backend.containerLogs(name, follow: false) {
                    try Task.checkCancellation()
                    historyCount += 1
                    if let tail {
                        if tail == 0 { continue }
                        if history.count < tail {
                            history.append(line)
                        } else {
                            history[oldest] = line
                            oldest = (oldest + 1) % tail
                        }
                    } else if !emit(line) {
                        continuation.finish()
                        return
                    }
                }
                for index in history.indices {
                    if !emit(history[(oldest + index) % history.count]) {
                        continuation.finish()
                        return
                    }
                }
                guard follow, item.state == .running else {
                    continuation.finish()
                    return
                }
                let skipCount = historyCount
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var skip = skipCount
                        for try await line in backend.containerLogs(name, follow: true) {
                            if skip > 0 { skip -= 1; continue }
                            if !emit(line) { return }
                        }
                    }
                    group.addTask {
                        // Docker ends `logs -f` when the container stops.
                        while true {
                            try await Task.sleep(for: .seconds(1))
                            let current = try? await directory.resolve(name)
                            if current?.state != .running {
                                try await Task.sleep(for: .milliseconds(300))   // let the last lines through
                                return
                            }
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        let type = tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream"
        return HTTPResponse(status: 200, headers: [("Content-Type", type)], body: .stream(stream))
    }

    // MARK: - Stats

    struct StatsJSON: Encodable {
        struct CPUUsage: Encodable {
            let total_usage: UInt64
            let usage_in_kernelmode: UInt64 = 0
            let usage_in_usermode: UInt64
        }
        struct Throttling: Encodable {
            let periods = 0
            let throttled_periods = 0
            let throttled_time = 0
        }
        struct CPUStats: Encodable {
            let cpu_usage: CPUUsage
            let system_cpu_usage: UInt64
            let online_cpus: Int
            let throttling_data = Throttling()
        }
        struct MemoryStats: Encodable {
            let usage: UInt64
            let limit: UInt64
            let stats: [String: UInt64]
        }
        struct Network: Encodable {
            let rx_bytes: UInt64
            let rx_packets = 0
            let rx_errors = 0
            let rx_dropped = 0
            let tx_bytes: UInt64
            let tx_packets = 0
            let tx_errors = 0
            let tx_dropped = 0
        }
        struct BlkioEntry: Encodable {
            let major = 0
            let minor = 0
            let op: String
            let value: UInt64
        }
        struct Blkio: Encodable {
            let io_service_bytes_recursive: [BlkioEntry]?
        }
        struct Pids: Encodable { let current: Int? }

        let read: String
        let preread: String
        let pids_stats: Pids
        let num_procs = 0
        let cpu_stats: CPUStats
        let precpu_stats: CPUStats
        let memory_stats: MemoryStats
        let networks: [String: Network]?
        let blkio_stats: Blkio
        let name: String
        let id: String
    }

    struct Sample {
        let stats: ContainerStats?
        let at: Date
        let started: Date

        func cpu(_ cpus: Int) -> StatsJSON.CPUStats {
            let usage = UInt64(max(0, stats?.cpuUsageUsec ?? 0)) * 1000
            // "System" time = wall clock × CPUs since start, so Docker's
            // Δcpu / Δsystem × online_cpus × 100 is percent of one core.
            let wall = max(0, at.timeIntervalSince(started))
            return .init(cpu_usage: .init(total_usage: usage, usage_in_usermode: usage),
                         system_cpu_usage: UInt64(wall * 1_000_000_000) * UInt64(max(1, cpus)),
                         online_cpus: max(1, cpus))
        }
    }

    static func json(_ current: Sample, previous: Sample?, item: DockerContainer) -> Data {
        let cpus = item.container.cpus
        let empty = StatsJSON.CPUStats(cpu_usage: .init(total_usage: 0, usage_in_usermode: 0),
                                       system_cpu_usage: 0, online_cpus: max(1, cpus))
        let stats = current.stats
        let value = StatsJSON(
            read: DockerTime.string(current.at),
            preread: previous.map { DockerTime.string($0.at) } ?? DockerTime.zero,
            pids_stats: .init(current: stats?.numProcesses),
            cpu_stats: stats == nil ? empty : current.cpu(cpus),
            precpu_stats: previous.map { $0.stats == nil ? empty : $0.cpu(cpus) } ?? empty,
            memory_stats: .init(usage: UInt64(max(0, stats?.memoryUsageBytes ?? 0)),
                                limit: UInt64(max(0, stats?.memoryLimitBytes ?? item.container.memoryInBytes)),
                                stats: ["inactive_file": 0]),
            networks: stats.map { ["eth0": .init(rx_bytes: UInt64(max(0, $0.networkRxBytes)),
                                                 tx_bytes: UInt64(max(0, $0.networkTxBytes)))] },
            blkio_stats: .init(io_service_bytes_recursive: stats.map {
                [.init(op: "read", value: UInt64(max(0, $0.blockReadBytes))),
                 .init(op: "write", value: UInt64(max(0, $0.blockWriteBytes)))]
            }),
            name: "/\(item.dockerName)",
            id: item.id)
        return ((try? JSONEncoder().encode(value)) ?? Data()) + Data("\n".utf8)
    }

    static func stats(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let item = try await directory.resolve(request.parameters["id"]!)
        let streaming = request.bool("stream", default: true)
        let oneShot = request.bool("one-shot")
        let started = item.container.startedDate ?? Date()

        func sample() async -> Sample {
            let stats = item.state == .running ? try? await backend.containerStats(item.name) : nil
            return Sample(stats: stats, at: Date(), started: started)
        }

        if !streaming {
            // Like Docker: two samples a second apart so precpu is set,
            // unless the client asked for one-shot.
            var previous: Sample?
            if !oneShot && item.state == .running {
                previous = await sample()
                try await Task.sleep(for: .seconds(1))
            }
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")],
                                body: .data(json(await sample(), previous: previous, item: item)))
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            var previous: Sample?
            while !Task.isCancelled {
                let current = await sample()
                continuation.yield(json(current, previous: previous, item: item))
                previous = current
                try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
    }
}
