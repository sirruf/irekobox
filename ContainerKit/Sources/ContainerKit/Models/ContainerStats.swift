import Foundation

/// One resource-usage sample from `container stats --format json`.
///
/// `cpuUsageUsec` is cumulative CPU time in microseconds, so CPU utilization is
/// derived from the delta between two samples over the elapsed interval.
public struct ContainerStats: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let cpuUsageUsec: Int64
    public let memoryUsageBytes: Int64
    public let memoryLimitBytes: Int64
    public let networkRxBytes: Int64
    public let networkTxBytes: Int64
    public let blockReadBytes: Int64
    public let blockWriteBytes: Int64
    public let numProcesses: Int

    public init(id: String, cpuUsageUsec: Int64, memoryUsageBytes: Int64, memoryLimitBytes: Int64,
                networkRxBytes: Int64, networkTxBytes: Int64, blockReadBytes: Int64, blockWriteBytes: Int64,
                numProcesses: Int) {
        self.id = id
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.numProcesses = numProcesses
    }

    /// Memory used as a fraction of the limit (0...1).
    public var memoryFraction: Double {
        guard memoryLimitBytes > 0 else { return 0 }
        return min(1, Double(memoryUsageBytes) / Double(memoryLimitBytes))
    }

    /// CPU utilization (%) between this sample and a previous one.
    /// Returns total across cores; divide by core count for per-core normalization.
    public func cpuPercent(since previous: ContainerStats, interval seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let deltaUsec = Double(cpuUsageUsec - previous.cpuUsageUsec)
        guard deltaUsec > 0 else { return 0 }
        return (deltaUsec / (seconds * 1_000_000)) * 100
    }
}

/// How a container's init process ended (XPC `containerWait`).
public struct ContainerExit: Hashable, Sendable {
    public let code: Int32
    public let exitedAt: Date?

    public init(code: Int32, exitedAt: Date?) {
        self.code = code
        self.exitedAt = exitedAt
    }
}
