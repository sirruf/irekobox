import Foundation
import Observation
import ContainerKit

/// State of one log viewer: the buffer, what's shown, and whether the view
/// follows new output. Incoming lines are batched (every 100 ms) so a chatty
/// container costs one UI update per batch, not per line.
@MainActor
@Observable
final class LogViewerModel {
    private(set) var buffer: LogBuffer
    var filter = LogFilter() {
        didSet { if filter != oldValue { rebuild() } }
    }
    var showTimestamps = true {
        didSet { if showTimestamps != oldValue { rebuild() } }
    }
    var wrapLines = false
    /// `false` while the user has scrolled away from the end.
    var isFollowing = true {
        didSet { if isFollowing { unseen = 0 } }
    }
    /// Lines that arrived (and pass the filter) while not following.
    private(set) var unseen = 0
    private(set) var matchCount = 0
    /// Warning and error lines kept, for the filter's label.
    private(set) var problemCount = 0
    private(set) var streamError: String?
    /// Bumped when the text must be redrawn from scratch.
    private(set) var generation = 0

    @ObservationIgnored private var pending: [String] = []
    /// Restarts and health changes around this log.
    @ObservationIgnored private var context = LogContext()

    /// Containers whose output this log shows (their changes become notes).
    func follow(_ ids: Set<String>) {
        context.followed = ids
    }

    /// The latest state of the followed containers and their neighbours.
    func observe(_ states: [String: LogContext.State], at time: Date = Date()) {
        let before = context.events.count
        let notes = context.update(states, at: time)
        guard !notes.isEmpty || context.events.count > before else { return }
        flush(at: time)
        for (text, note) in notes { addNote(text, note, at: time) }
        // Polling sees a change seconds late; errors it caused may already be in.
        let recent = buffer.entries.reversed()
            .prefix { time.timeIntervalSince($0.time) <= LogContext.closeWindow }
            .reversed()
            .filter { $0.level >= .warning && $0.note == nil }
        for entry in recent {
            if let (text, note) = context.explain(entry.text, level: entry.level, at: entry.time) {
                addNote(text, note, at: time)
                break
            }
        }
    }

    private func addNote(_ text: String, _ note: LogNote, at time: Date) {
        let entry = buffer.appendNote(text, note, at: time)
        if !isFollowing && filter.matches(entry) { unseen += 1 }
    }

    init(capacity: Int = 50_000) {
        buffer = LogBuffer(capacity: capacity)
    }

    var visibleEntries: [LogEntry] { buffer.visible(filter) }

    /// Follow any line stream (e.g. kubectl logs) until the calling task is cancelled.
    func stream(lines: AsyncThrowingStream<String, Error>, flushEvery interval: Duration = .milliseconds(100)) async {
        streamError = nil
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.flush()
            }
        }
        defer { ticker.cancel() }
        do {
            for try await line in lines { pending.append(line) }
        } catch is CancellationError {
        } catch {
            streamError = error.localizedDescription
        }
        flush()
    }

    /// Follow `id`'s output until the calling task is cancelled.
    func stream(engine: any ContainerEngine, id: String, flushEvery interval: Duration = .milliseconds(100)) async {
        streamError = nil
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.flush()
            }
        }
        defer { ticker.cancel() }
        do {
            for try await line in engine.containerLogs(id, follow: true) {
                pending.append(line)
            }
        } catch is CancellationError {
        } catch {
            streamError = error.localizedDescription
        }
        flush()
    }

    /// Width of the `web  | ` labels while following several containers
    /// (0 otherwise), so the view can color them.
    var labelWidth = 0
    /// The labels in order: their colors follow it.
    var labels: [String] = []

    /// Follow several containers at once, each line prefixed like
    /// `docker compose logs` (`web  | …`), until the calling task is cancelled.
    func stream(engine: any ContainerEngine, sources: [(label: String, id: String)],
                flushEvery interval: Duration = .milliseconds(100)) async {
        streamError = nil
        let width = sources.map(\.label.count).max() ?? 0
        labelWidth = width
        labels = sources.map(\.label)
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.flush()
            }
        }
        defer { ticker.cancel() }
        let followers = sources.map { source in
            let prefix = source.label.padding(toLength: width, withPad: " ", startingAt: 0) + " | "
            return Task { @MainActor [weak self] () -> String? in
                do {
                    for try await line in engine.containerLogs(source.id, follow: true) {
                        self?.pending.append(prefix + line)
                    }
                } catch is CancellationError {
                } catch {
                    return "\(source.label): \(error.localizedDescription)"
                }
                return nil
            }
        }
        await withTaskCancellationHandler {
            for follower in followers {
                if let failure = await follower.value { streamError = failure }
            }
        } onCancel: {
            for follower in followers { follower.cancel() }
        }
        flush()
    }

    /// Move pending lines into the buffer (also used by tests).
    func ingest(_ lines: [String], at time: Date = Date()) {
        pending.append(contentsOf: lines)
        flush(at: time)
    }

    private func flush(at time: Date = Date()) {
        guard !pending.isEmpty else { return }
        let added = buffer.append(pending, at: time)
        pending.removeAll(keepingCapacity: true)
        let shown = added.filter(filter.matches)
        if !isFollowing { unseen += shown.count }
        matchCount += LogBuffer.matchCount(filter.query, in: shown)
        problemCount += added.count { $0.level >= .warning }
        // An explanation goes after the batch with the error it explains.
        for entry in added {
            if let (text, note) = context.explain(entry.text, level: entry.level, at: time) {
                addNote(text, note, at: time)
            }
        }
    }

    func clear() {
        buffer.clear()
        rebuild()
    }

    /// The visible text, as shown (for Copy and Export).
    func visibleText() -> String {
        visibleEntries.map { line(for: $0) }.joined(separator: "\n")
    }

    func line(for entry: LogEntry) -> String {
        showTimestamps ? "\(Self.timeFormatter.string(from: entry.time))  \(entry.text)" : entry.text
    }

    private func rebuild() {
        matchCount = LogBuffer.matchCount(filter.query, in: visibleEntries)
        problemCount = buffer.entries.count { $0.level >= .warning && $0.note == nil }
        unseen = 0
        generation &+= 1
    }

    nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
