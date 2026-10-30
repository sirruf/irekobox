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
        didSet { if filter != oldValue { search() } }
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

    /// The last completed search; appends use it until the next search commits.
    private(set) var displayFilter = LogFilter()
    @ObservationIgnored private var filteredEntries: [LogEntry] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchVersion = 0
    @ObservationIgnored private var pending = LogPending()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
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
        let firstKept = buffer.firstID
        let entry = buffer.appendNote(text, note, at: time)
        if buffer.firstID != firstKept { filteredEntries.removeAll { $0.id < buffer.firstID } }
        if displayFilter.matches(entry) {
            if displayFilter != LogFilter() { filteredEntries.append(entry) }
            if !isFollowing { unseen += 1 }
            matchCount += LogBuffer.matchCount(displayFilter.query, in: [entry])
        }
        if buffer.firstID != firstKept {
            matchCount = LogBuffer.matchCount(displayFilter.query, in: visibleEntries)
            problemCount = buffer.entries.count { $0.level >= .warning && $0.note == nil }
        }
    }

    init(capacity: Int = 50_000) {
        buffer = LogBuffer(capacity: capacity)
    }

    var visibleEntries: [LogEntry] { displayFilter == LogFilter() ? buffer.entries : filteredEntries }

    /// Follow any line stream (e.g. kubectl logs) until the calling task is cancelled.
    func stream(lines: AsyncThrowingStream<String, Error>, flushEvery interval: Duration = .milliseconds(100)) async {
        streamError = nil
        defer { flush() }
        do {
            for try await line in lines { enqueue(line, flushEvery: interval) }
        } catch is CancellationError {
        } catch {
            streamError = error.localizedDescription
        }
    }

    /// Follow `id`'s output until the calling task is cancelled.
    func stream(engine: any ContainerEngine, id: String, flushEvery interval: Duration = .milliseconds(100)) async {
        await self.stream(lines: engine.containerLogs(id, follow: true), flushEvery: interval)
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
        defer { flush() }
        let followers = sources.map { source in
            let prefix = source.label.padding(toLength: width, withPad: " ", startingAt: 0) + " | "
            return Task { @MainActor [weak self] () -> String? in
                do {
                    for try await line in engine.containerLogs(source.id, follow: true) {
                        self?.enqueue(prefix + line, flushEvery: interval)
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
    }

    /// Move pending lines into the buffer (also used by tests).
    func ingest(_ lines: [String], at time: Date = Date()) {
        for line in lines { pending.append(line) }
        flush(at: time)
    }

    private func enqueue(_ line: String, flushEvery interval: Duration) {
        pending.append(line)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            self?.flush()
        }
    }

    private func flush(at time: Date = Date()) {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.lines.isEmpty else { return }
        let firstKept = buffer.firstID
        let added = buffer.append(pending.lines, at: time)
        pending.removeAll()
        if buffer.firstID != firstKept {
            filteredEntries.removeAll { $0.id < buffer.firstID }
        }
        let shown = added.filter { $0.id >= buffer.firstID && displayFilter.matches($0) }
        if displayFilter != LogFilter() { filteredEntries.append(contentsOf: shown) }
        if !isFollowing { unseen += shown.count }
        matchCount += LogBuffer.matchCount(displayFilter.query, in: shown)
        problemCount += added.count { $0.level >= .warning }
        if buffer.firstID != firstKept {
            matchCount = LogBuffer.matchCount(displayFilter.query, in: visibleEntries)
            problemCount = buffer.entries.count { $0.level >= .warning && $0.note == nil }
        }
        // An explanation goes after the batch with the error it explains.
        for entry in added {
            if let (text, note) = context.explain(entry.text, level: entry.level, at: time) {
                addNote(text, note, at: time)
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        searchVersion &+= 1
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        buffer.clear()
        filteredEntries = []
        displayFilter = filter
        rebuild()
    }

    /// The visible text, as shown (for Copy and Export).
    func visibleText() -> String {
        visibleEntries.map { line(for: $0) }.joined(separator: "\n")
    }

    func line(for entry: LogEntry) -> String {
        showTimestamps ? "\(Self.timeFormatter.string(from: entry.time))  \(entry.text)" : entry.text
    }

    /// Debounce typing, filter/count off the main actor, then publish only the
    /// current version. Lines arriving during the search are merged at commit.
    private func search() {
        searchTask?.cancel()
        searchVersion &+= 1
        let version = searchVersion
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            let filter = self.filter
            let entries = buffer.entries
            let lastID = entries.last?.id ?? -1
            let work = Task.detached(priority: .userInitiated) {
                let shown = entries.filter { !Task.isCancelled && filter.matches($0) }
                return (shown, LogBuffer.matchCount(filter.query, in: shown))
            }
            let (shown, count) = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, version == searchVersion else { return }
            let removed = shown.prefix { $0.id < buffer.firstID }
            let fresh = buffer.entries.reversed().prefix { $0.id > lastID }.reversed().filter(filter.matches)
            filteredEntries = Array(shown.dropFirst(removed.count)) + fresh
            displayFilter = filter
            matchCount = count - LogBuffer.matchCount(filter.query, in: Array(removed))
                + LogBuffer.matchCount(filter.query, in: fresh)
            unseen = 0
            generation &+= 1
            searchTask = nil
        }
    }

    private func rebuild() {
        matchCount = LogBuffer.matchCount(displayFilter.query, in: visibleEntries)
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
