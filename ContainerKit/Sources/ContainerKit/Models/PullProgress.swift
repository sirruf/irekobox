import Foundation

/// One `container image pull --progress plain` line, parsed:
/// `[1/2] Fetching image 49% (35 of 52 blobs, 8.2/16.7 MB, 3.8 MB/s) [6s]`.
public struct PullProgress: Equatable, Sendable {
    public let step: Int
    public let totalSteps: Int
    /// "Fetching image", "Unpacking image for platform linux/arm64", …
    public let phase: String
    /// 0…1 within the step, when the line has a percentage.
    public let fraction: Double?
    /// "8.2/16.7 MB, 3.8 MB/s", when present.
    public let detail: String?

    /// Overall 0…1 across steps (each step an equal share), when known.
    public var overall: Double? {
        guard totalSteps > 0 else { return nil }
        let done = Double(step - 1) / Double(totalSteps)
        guard let fraction else { return done }
        return min(1, done + fraction / Double(totalSteps))
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\[(\d+)/(\d+)\]\s+(.*?)(?:\s+(\d+)%)?(?:\s+\((.*)\))?\s+\[\d+[smh]\]\s*$"#)

    public static func parse(_ line: String) -> PullProgress? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
        guard let step = group(1).flatMap(Int.init), let total = group(2).flatMap(Int.init),
              let phase = group(3) else { return nil }
        let fraction = group(4).flatMap(Double.init).map { $0 / 100 }
        let detail = group(5).map { inner -> String in
            // Drop the blob count ("35 of 52 blobs, "), keep sizes and speed.
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let kept = parts.filter { !$0.hasSuffix("blobs") && !$0.hasSuffix("entries") }
            return kept.isEmpty ? inner : kept.joined(separator: ", ")
        }
        return PullProgress(step: step, totalSteps: total, phase: phase, fraction: fraction, detail: detail)
    }
}
