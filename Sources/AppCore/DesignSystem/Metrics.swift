import SwiftUI

/// A thin horizontal usage bar with a label row: "Memory    214 MB of 1 GB".
struct MetricBar: View {
    let title: LocalizedStringKey
    let value: String
    /// 0...1
    let fraction: Double
    var tone: Tone = .info

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.subtleFill)
                    Capsule().fill(tone.fill)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A minimal line chart of recent samples (CPU history in a table cell).
struct Sparkline: View {
    /// Samples, oldest first; scaled to `maxValue` (or their own max).
    let samples: [Double]
    var maxValue: Double?
    var tone: Tone = .info

    var body: some View {
        GeometryReader { proxy in
            let top = max(maxValue ?? samples.max() ?? 1, 0.0001)
            Path { path in
                guard samples.count > 1 else { return }
                let step = proxy.size.width / CGFloat(samples.count - 1)
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: proxy.size.height * (1 - CGFloat(min(sample, top) / top)))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(tone.fill, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

#Preview("Metrics") {
    VStack(spacing: 16) {
        MetricBar(title: "Memory", value: "214 MB of 1 GB", fraction: 0.21)
        MetricBar(title: "Disk", value: "5.6 GB", fraction: 0.8, tone: .warning)
        Sparkline(samples: [2, 3, 2, 7, 5, 12, 8, 10, 6, 12]).frame(width: 60, height: 16)
    }
    .padding()
    .frame(width: 320)
}

/// A usage ring with its value in the middle and a caption below
/// ("23%" · "CPU · 10 cores").
struct UsageRing: View {
    let value: String
    let caption: LocalizedStringResource
    /// 0...1
    let fraction: Double
    var color: Color = DS.accent
    var size: CGFloat = 96
    /// What VoiceOver reads ("CPU 23 percent").
    var accessibilityText: LocalizedStringResource?

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            ZStack {
                Circle().stroke(DS.subtleFill, lineWidth: size * 0.094)
                Circle()
                    .trim(from: 0, to: min(1, max(0.005, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.094, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(size: size * 0.18, weight: .bold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, size * 0.14)
            }
            .frame(width: size, height: size)
            .animation(.smooth, value: fraction)
            // Two lines: captions run longer in other languages.
            Text(String(localized: caption)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: size * 1.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText.map { String(localized: $0) } ?? "\(String(localized: caption)), \(value)")
    }
}
