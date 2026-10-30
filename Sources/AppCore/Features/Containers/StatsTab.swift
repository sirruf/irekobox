import SwiftUI
import Charts
import ContainerKit

/// Stats tab: CPU, memory, network and disk activity. The last five minutes
/// are sampled every two seconds while the tab is open; the last hour and day
/// come from the app-wide `StatsRecorder`.
struct StatsTab: View {
    @Environment(AppState.self) private var app
    let container: Container

    enum Range: String, CaseIterable, Identifiable {
        case fiveMinutes, hour, day
        var id: Self { self }
        var seconds: TimeInterval {
            switch self {
            case .fiveMinutes: StatsHistory.window
            case .hour: 3600
            case .day: 24 * 3600
            }
        }
        var title: String {
            switch self {
            case .fiveMinutes: String(localized: "5 min", comment: "Stats range")
            case .hour: String(localized: "1 hour", comment: "Stats range")
            case .day: String(localized: "1 day", comment: "Stats range")
            }
        }
        /// Grid lines on the time axis, in seconds before now.
        var ticks: [Double] {
            switch self {
            case .fiveMinutes: [-300, -240, -180, -120, 0]   // no -60: it would crowd "now"
            case .hour: [-3600, -2700, -1800, 0]
            case .day: [-86_400, -64_800, -43_200, 0]
            }
        }
    }

    @State private var history = StatsHistory()
    @State private var error: String?
    @AppStorage("statsRange") private var range: Range = .fiveMinutes

    /// What the charts draw for the chosen range.
    private var points: [StatsHistory.Point] {
        range == .fiveMinutes ? history.points
            : app.statsRecorder.points(container.id, range: range.seconds)
    }

    private let interval: Duration = .seconds(2)

    var body: some View {
        Group {
            if !container.state.isRunning {
                ContentUnavailableView("Container Not Running",
                                       systemImage: "pause.circle",
                                       description: Text("Start it to see live resource usage."))
            } else if let error, history.latest == nil {
                ContentUnavailableView("Stats Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if history.points.isEmpty {
                ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .task(id: "\(container.id)-\(container.state.isRunning)") { await poll() }
    }

    // MARK: - Layout

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                summary
                rangeBar
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: DS.Spacing.l, alignment: .top)],
                          spacing: DS.Spacing.l) {
                    cpuChart
                    memoryChart
                    networkChart
                    diskChart
                }
                if let error {
                    NoticeBanner(tone: .warning, title: "Latest sample failed", message: error)
                }
            }
            .padding(DS.Spacing.l)
        }
        .accessibilityIdentifier("stats.content")
    }

    private var summary: some View {
        let point = history.last
        let latest = history.latest
        return HStack(spacing: DS.Spacing.xl) {
            figure("CPU", point.map { "\(Int($0.cpuPercent.rounded()))%" } ?? "—",
                   detail: String(localized: "of \(container.cpus) CPUs"))
            figure("Memory", latest.map { Format.memory($0.memoryUsageBytes) } ?? "—",
                   detail: latest.map { String(localized: "of \(Format.memory($0.memoryLimitBytes))") } ?? "")
            figure("Network", point.map { "↓ \(Format.rate($0.networkInPerSecond))" } ?? "—",
                   detail: point.map { "↑ \(Format.rate($0.networkOutPerSecond))" } ?? "")
            figure("Disk", point.map { String(localized: "R \(Format.rate($0.diskReadPerSecond))", comment: "Disk read rate") } ?? "—",
                   detail: point.map { String(localized: "W \(Format.rate($0.diskWritePerSecond))", comment: "Disk write rate") } ?? "")
            figure("Processes", latest.map { "\($0.numProcesses)" } ?? "—", detail: "")
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("stats.summary")
    }

    private var rangeBar: some View {
        HStack(spacing: DS.Spacing.m) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("stats.range")
            if let note = rangeNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Why a longer range may be short or empty.
    private var rangeNote: String? {
        switch range {
        case .fiveMinutes:
            return String(localized: "Every 2 seconds while this tab is open")
        case .hour, .day:
            let since = app.statsRecorder.startedAt
            guard Date().timeIntervalSince(since) < range.seconds else { return String(localized: "Every 15 seconds, averaged over 5 minutes in the day view") }
            return String(localized: "Recorded while Irekobox is open — since \(since.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Charts

    private var cpuChart: some View {
        // Full scale is every core busy, so "is it maxed out" reads at a glance.
        let ceiling = Double(max(1, container.cpus) * 100)
        return MetricChart(
            identifier: "cpu", title: String(localized: "CPU"), unitNote: String(localized: "% of one core"),
            points: points, range: range,
            series: [.init(name: String(localized: "CPU"), value: \.cpuPercent)],
            yMax: max(ceiling, peak(\.cpuPercent)),
            format: { "\(Int($0.rounded()))%" })
    }

    private var memoryChart: some View {
        let limit = Double(history.latest?.memoryLimitBytes ?? 0)
        return MetricChart(
            identifier: "memory", title: String(localized: "Memory"), unitNote: String(localized: "used of the limit"),
            points: points, range: range,
            series: [.init(name: String(localized: "Used", comment: "Memory in use"), value: { Double($0.memoryBytes) })],
            yMax: max(limit, peak { Double($0.memoryBytes) }),
            limit: limit > 0 ? limit : nil,
            // Halves of the limit read as "512 MB", not "476.8 MB".
            yTicks: limit > 0 ? [0, limit / 2, limit] : nil,
            format: { $0 < 1 ? "0" : Format.memory(Int64($0)) })
    }

    private var networkChart: some View {
        MetricChart(
            identifier: "network", title: String(localized: "Network"), unitNote: String(localized: "per second"),
            points: points, range: range,
            series: [.init(name: String(localized: "In", comment: "Network traffic received"), value: \.networkInPerSecond),
                     .init(name: String(localized: "Out", comment: "Network traffic sent"), value: \.networkOutPerSecond)],
            yMax: max(1024, peak { max($0.networkInPerSecond, $0.networkOutPerSecond) }),
            format: Format.rate)
    }

    private var diskChart: some View {
        MetricChart(
            identifier: "disk", title: String(localized: "Disk"), unitNote: String(localized: "per second"),
            points: points, range: range,
            series: [.init(name: String(localized: "Read", comment: "Disk bytes read"), value: \.diskReadPerSecond),
                     .init(name: String(localized: "Write", comment: "Disk bytes written"), value: \.diskWritePerSecond)],
            yMax: max(1024, peak { max($0.diskReadPerSecond, $0.diskWritePerSecond) }),
            format: Format.rate)
    }

    private func peak(_ metric: (StatsHistory.Point) -> Double) -> Double {
        points.map(metric).max() ?? 0
    }

    // MARK: - Polling

    private func poll() async {
        history.reset()
        error = nil
        guard container.state.isRunning else { return }
        while !Task.isCancelled {
            do {
                let stats = try await app.engine.containerStats(container.id)
                history.add(stats, at: Date())
                error = nil
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: interval)
        }
    }
}

/// One measure over the stats window: a line per series against "time ago",
/// a hover rule with the values at that moment, and a legend when there is
/// more than one series.
private struct MetricChart: View {
    struct Series: Identifiable {
        let name: String
        let value: (StatsHistory.Point) -> Double
        var id: String { name }
    }

    /// For the accessibility identifier ("stats.chart.cpu").
    let identifier: String
    let title: String
    let unitNote: String
    let points: [StatsHistory.Point]
    let range: StatsTab.Range
    let series: [Series]
    let yMax: Double
    var limit: Double?
    var yTicks: [Double]?
    let format: (Double) -> String

    @State private var hoverSecondsAgo: Double?

    /// The right edge: the newest live sample, or the present for recorded ranges.
    private var now: Date { range == .fiveMinutes ? points.last?.time ?? Date() : Date() }

    private func secondsAgo(_ point: StatsHistory.Point) -> Double {
        point.time.timeIntervalSince(now)
    }

    /// The sample nearest the pointer.
    private var hovered: StatsHistory.Point? {
        guard let hoverSecondsAgo else { return nil }
        return points.min { abs(secondsAgo($0) - hoverSecondsAgo) < abs(secondsAgo($1) - hoverSecondsAgo) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            header
            chart
                .frame(height: 150)
                .overlay {
                    if points.isEmpty {
                        Text("Nothing recorded yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stats.chart.\(identifier)")
    }

    private var header: some View {
        let shown = hovered ?? points.last
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Text(unitNote).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if hovered == nil, series.count == 1, let item = series.first, let shown {
                // At rest one measure reads as now, the typical level and the worst moment.
                let values = points.map(item.value)
                let average = values.reduce(0, +) / Double(max(1, values.count))
                let peak = format(values.max() ?? 0)
                // Against a limit the limit matters more than the average.
                Text(limit.map { String(localized: "\(format(item.value(shown))) of \(format($0)) · peak \(peak)") }
                     ?? String(localized: "now \(format(item.value(shown))) · avg \(format(average)) · peak \(peak)"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            } else if let shown {
                HStack(spacing: DS.Spacing.m) {
                    ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: DS.Spacing.xs) {
                            if series.count > 1 {
                                Circle().fill(DS.series[index]).frame(width: 8, height: 8)
                                Text(item.name).foregroundStyle(.secondary)
                            }
                            Text(format(item.value(shown))).monospacedDigit()
                        }
                    }
                    if hovered != nil {
                        Text("\(Format.duration(-secondsAgo(shown))) ago").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: range.ticks) { value in
            let seconds = value.as(Double.self) ?? 0
            AxisGridLine().foregroundStyle(DS.separator.opacity(0.5))
            // "now" sits at the right edge: anchor it inside the plot.
            AxisValueLabel(anchor: seconds == 0 ? .topTrailing : .top) {
                Text(seconds == 0 ? "now" : "\(Format.duration(-seconds)) ago")
            }
        }
    }

    private var yValues: [Double] {
        yTicks ?? StatsHistory.niceTicks(upTo: yMax)
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: yValues) { value in
            AxisGridLine().foregroundStyle(DS.separator.opacity(0.5))
            AxisValueLabel {
                Text(format(value.as(Double.self) ?? 0))
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                ForEach(points) { point in
                    LineMark(x: .value("Time", secondsAgo(point)),
                             y: .value(item.name, item.value(point)),
                             series: .value("Series", item.name))
                        .foregroundStyle(DS.series[index])
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if series.count == 1 {
                    ForEach(points) { point in
                        AreaMark(x: .value("Time", secondsAgo(point)),
                                 y: .value(item.name, item.value(point)))
                            .foregroundStyle(DS.series[index].opacity(0.12))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            if let limit {
                RuleMark(y: .value("Limit", limit))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("limit \(format(limit))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let hovered {
                RuleMark(x: .value("Time", secondsAgo(hovered)))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: -range.seconds...0)
        .chartYScale(domain: 0...max(yMax, 1) * 1.08)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartXSelection(value: $hoverSecondsAgo)
        .chartLegend(.hidden)   // the header names the series next to their values
        .accessibilityLabel(title)
        .accessibilityValue(points.last.map { point in
            series.map { "\($0.name) \(format($0.value(point)))" }.joined(separator: ", ")
        } ?? "")
    }
}
