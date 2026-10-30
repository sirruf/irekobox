import Foundation
import ContainerKit

/// A rolling window of resource samples for one container. `container stats`
/// reports cumulative counters (CPU time, bytes in/out); this turns them into
/// rates between consecutive samples.
struct StatsHistory {
    struct Point: Identifiable, Hashable {
        var id: Date { time }
        let time: Date
        /// Total across cores: 250 means two and a half cores busy.
        let cpuPercent: Double
        let memoryBytes: Int64
        let networkInPerSecond: Double
        let networkOutPerSecond: Double
        let diskReadPerSecond: Double
        let diskWritePerSecond: Double
    }

    /// How far back the live charts go.
    static let window: TimeInterval = 5 * 60

    /// How far back this history keeps points.
    let span: TimeInterval
    private(set) var points: [Point] = []
    private(set) var latest: ContainerStats?
    private(set) var latestTime: Date?

    init(span: TimeInterval = StatsHistory.window) {
        self.span = span
    }

    mutating func add(_ stats: ContainerStats, at time: Date) {
        defer {
            latest = stats
            latestTime = time
        }
        // The first sample has nothing to diff against; a restarted container
        // resets its counters, which would read as a huge negative rate.
        guard let previous = latest, let previousTime = latestTime else { return }
        let elapsed = time.timeIntervalSince(previousTime)
        guard elapsed > 0 else { return }
        func rate(_ now: Int64, _ before: Int64) -> Double {
            now >= before ? Double(now - before) / elapsed : 0
        }
        points.append(Point(
            time: time,
            cpuPercent: stats.cpuPercent(since: previous, interval: elapsed),
            memoryBytes: stats.memoryUsageBytes,
            networkInPerSecond: rate(stats.networkRxBytes, previous.networkRxBytes),
            networkOutPerSecond: rate(stats.networkTxBytes, previous.networkTxBytes),
            diskReadPerSecond: rate(stats.blockReadBytes, previous.blockReadBytes),
            diskWritePerSecond: rate(stats.blockWriteBytes, previous.blockWriteBytes)))
        let cutoff = time.addingTimeInterval(-span)
        points.removeAll { $0.time < cutoff }
    }

    mutating func reset() {
        self = StatsHistory(span: span)
    }

    var last: Point? { points.last }

    /// One point per `bucket` seconds: the average of each measure over the
    /// points in it, stamped at the bucket's middle. Long ranges stay readable
    /// (a day of 15-second samples would be a solid band).
    static func averaged(_ points: [Point], bucket: TimeInterval) -> [Point] {
        guard bucket > 0 else { return points }
        var result: [Point] = []
        var group: [Point] = []
        var groupStart: TimeInterval?
        func close() {
            guard let start = groupStart, !group.isEmpty else { return }
            let count = Double(group.count)
            func mean(_ value: (Point) -> Double) -> Double { group.map(value).reduce(0, +) / count }
            result.append(Point(
                time: Date(timeIntervalSinceReferenceDate: start + bucket / 2),
                cpuPercent: mean(\.cpuPercent),
                memoryBytes: Int64(mean { Double($0.memoryBytes) }.rounded()),
                networkInPerSecond: mean(\.networkInPerSecond),
                networkOutPerSecond: mean(\.networkOutPerSecond),
                diskReadPerSecond: mean(\.diskReadPerSecond),
                diskWritePerSecond: mean(\.diskWritePerSecond)))
            group = []
        }
        for point in points {
            let start = (point.time.timeIntervalSinceReferenceDate / bucket).rounded(.down) * bucket
            if start != groupStart {
                close()
                groupStart = start
            }
            group.append(point)
        }
        close()
        return result
    }

    /// Round axis ticks from 0 to at least `maximum`, two or three steps of
    /// 1, 2 or 5 times a power of ten.
    static func niceTicks(upTo maximum: Double) -> [Double] {
        guard maximum > 0 else { return [0] }
        let rough = maximum / 2
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? rough
        return stride(from: 0, through: maximum, by: step).map { $0 }
    }

    /// The highest value of `metric` in the window, for scales that shouldn't
    /// flatten small activity against a fixed maximum.
    func peak(_ metric: (Point) -> Double) -> Double {
        points.map(metric).max() ?? 0
    }
}

extension Format {
    /// "1.2 MB/s"; "0 B/s" for idle (ByteCountFormatter would say "Zero KB").
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 1 else { return String(localized: "0 B/s") }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let amount = formatter.string(fromByteCount: Int64(bytesPerSecond.rounded()))
        return String(localized: "\(amount)/s", comment: "A transfer rate: an amount per second")
    }
}
