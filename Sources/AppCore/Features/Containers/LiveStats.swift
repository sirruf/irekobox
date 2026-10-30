import Foundation
import Observation
import ContainerKit

/// Samples CPU and memory of running containers while a screen shows them —
/// for the table's sparklines and the inspector. One `stats` call per container
/// per tick (cheap over XPC); nothing runs once the calling task ends.
@MainActor
@Observable
final class LiveStats {
    struct Series: Equatable {
        /// CPU % of one core, oldest first (can exceed 100 with several cores).
        var cpu: [Double] = []
        var memoryUsage: Int64 = 0
        var memoryLimit: Int64 = 0
        /// Bytes per second received and sent, over the last tick.
        var networkIn: Double = 0
        var networkOut: Double = 0

        var latestCPU: Double? { cpu.last }
        var memoryFraction: Double { memoryLimit > 0 ? Double(memoryUsage) / Double(memoryLimit) : 0 }
    }

    static let historyLength = 30

    private(set) var series: [String: Series] = [:]
    @ObservationIgnored private var previous: [String: (stats: ContainerStats, at: ContinuousClock.Instant)] = [:]

    /// Sample every `interval` until the calling task is cancelled. `ids`
    /// is re-read each tick so the set follows the visible list.
    func run(engine: any ContainerEngine, interval: Duration = .seconds(2),
             ids: @escaping @MainActor () -> [String]) async {
        while !Task.isCancelled {
            await sample(engine: engine, ids: ids())
            try? await Task.sleep(for: interval)
        }
    }

    func sample(engine: any ContainerEngine, ids: [String]) async {
        let results = await withTaskGroup(of: (String, ContainerStats?).self) { group in
            for id in ids {
                group.addTask { (id, try? await engine.containerStats(id)) }
            }
            var collected: [(String, ContainerStats?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        guard !Task.isCancelled else { return }
        let now = ContinuousClock.now
        let wanted = Set(ids)
        // Forget containers that are gone or no longer running.
        for id in series.keys where !wanted.contains(id) { series[id] = nil }
        for id in previous.keys where !wanted.contains(id) { previous[id] = nil }

        for (id, stats) in results {
            guard let stats else {
                if series[id] != nil { series[id] = nil }
                previous[id] = nil
                continue
            }
            var entry = series[id] ?? Series()
            if let last = previous[id] {
                let seconds = Double((now - last.at).components.seconds)
                    + Double((now - last.at).components.attoseconds) / 1e18
                entry.cpu.append(stats.cpuPercent(since: last.stats, interval: seconds))
                if seconds > 0 {
                    entry.networkIn = max(0, Double(stats.networkRxBytes - last.stats.networkRxBytes) / seconds)
                    entry.networkOut = max(0, Double(stats.networkTxBytes - last.stats.networkTxBytes) / seconds)
                }
                if entry.cpu.count > Self.historyLength { entry.cpu.removeFirst(entry.cpu.count - Self.historyLength) }
            }
            entry.memoryUsage = stats.memoryUsageBytes
            entry.memoryLimit = stats.memoryLimitBytes
            if series[id] != entry { series[id] = entry }
            previous[id] = (stats, now)
        }
    }
}
