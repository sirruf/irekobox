import Foundation
import Observation
import ContainerKit

/// Resource history beyond the Stats tab's live five minutes: every running
/// container is sampled every 15 seconds while the app runs, and the last day
/// is kept. One `stats` call per running container per tick (cheap over XPC).
@MainActor
@Observable
final class StatsRecorder {
    static let interval: Duration = .seconds(15)
    static let span: TimeInterval = 24 * 3600

    /// Container id → its history.
    private(set) var histories: [String: StatsHistory] = [:]
    /// When recording began: the history can't reach further back.
    private(set) var startedAt = Date()

    private struct CachedPoints {
        let latestSample: Date?
        let cutoff: Date
        /// Reuse until the first included sample leaves the range. This also
        /// expires stopped containers' charts without another sample arriving.
        let firstIncluded: Date?
        let points: [StatsHistory.Point]
    }
    @ObservationIgnored private var pointCache: [String: [TimeInterval: CachedPoints]] = [:]

    /// Sample until the calling task is cancelled. `targets` is re-read each
    /// tick: the engine (it can be replaced), the running ids, and every id
    /// that still exists (history of a stopped container is kept until it's removed).
    func run(_ targets: @escaping @MainActor () -> (engine: any ContainerEngine, running: [String], existing: Set<String>)) async {
        startedAt = Date()
        while !Task.isCancelled {
            let (engine, running, existing) = targets()
            let results = await withTaskGroup(of: (String, ContainerStats?).self) { group in
                for id in running {
                    group.addTask { (id, try? await engine.containerStats(id)) }
                }
                var collected: [(String, ContainerStats?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            record(results.compactMap { id, stats in stats.map { (id, $0) } }, existing: existing)
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Add one round of samples (also used by tests).
    func record(_ samples: [(id: String, stats: ContainerStats)], existing: Set<String>, at time: Date = Date()) {
        var histories = self.histories.filter { existing.contains($0.key) }
        for id in pointCache.keys where !existing.contains(id) { pointCache[id] = nil }
        for (id, stats) in samples {
            var history = histories[id] ?? StatsHistory(span: Self.span)
            history.add(stats, at: time)
            histories[id] = history
            pointCache[id] = nil
        }
        self.histories = histories
    }

    /// Points of `id` over the last `range` seconds; averaged into 5-minute
    /// buckets beyond an hour so a day stays readable.
    func points(_ id: String, range: TimeInterval, now: Date = Date()) -> [StatsHistory.Point] {
        guard let history = histories[id] else { return [] }
        let cutoff = now.addingTimeInterval(-range)
        if let cached = pointCache[id]?[range], cached.latestSample == history.latestTime,
           cutoff >= cached.cutoff, cached.firstIncluded.map({ cutoff <= $0 }) ?? true {
            return cached.points
        }
        let recent = history.points.drop(while: { $0.time < cutoff })
        let points = range > 3600 ? StatsHistory.averaged(Array(recent), bucket: 300) : Array(recent)
        pointCache[id, default: [:]][range] = CachedPoints(latestSample: history.latestTime, cutoff: cutoff,
                                                        firstIncluded: recent.first?.time, points: points)
        return points
    }
}
