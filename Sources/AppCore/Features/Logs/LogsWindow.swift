import SwiftUI

/// What a logs window follows: a project's services, or one container.
public struct LogsTarget: Codable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        public let label: String
        public let id: String
    }

    public let title: String
    public let sources: [Source]
}

/// Logs in their own window ("Logs — shop"): a chip per service to show or
/// hide it, each in the color its lines carry.
public struct LogsWindow: View {
    let target: LogsTarget?
    @State private var hidden: Set<String> = []

    public init(target: LogsTarget?) { self.target = target }

    public var body: some View {
        Group {
            if let target {
                let shown = target.sources.filter { !hidden.contains($0.label) }
                VStack(spacing: 0) {
                    if target.sources.count > 1 {
                        chips(target)
                        Divider()
                    }
                    if target.sources.isEmpty {
                        ContentUnavailableView("No Containers", systemImage: "text.alignleft",
                                               description: Text("Start \(target.title) to see its services' output here."))
                    } else if shown.isEmpty {
                        ContentUnavailableView("Every Service Hidden", systemImage: "eye.slash",
                                               description: Text("Click a service above to show its lines."))
                    } else {
                        LogsTab(id: target.title, sources: shown.map { (label: $0.label, id: $0.id) })
                    }
                }
                .navigationTitle("Logs — \(target.title)")
            } else {
                ContentUnavailableView("No Logs", systemImage: "text.alignleft")
            }
        }
        .frame(minWidth: 560, minHeight: 300)
    }

    private func chips(_ target: LogsTarget) -> some View {
        let labels = target.sources.map(\.label)
        return HStack(spacing: DS.Spacing.s) {
            ForEach(target.sources, id: \.self) { source in
                let on = !hidden.contains(source.label)
                let color = Color(nsColor: LogLabelColor.color(for: source.label, in: labels))
                Button {
                    if on { hidden.insert(source.label) } else { hidden.remove(source.label) }
                } label: {
                    Text(source.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(on ? color : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(on ? color.opacity(0.14) : Color.clear))
                        .overlay(Capsule().strokeBorder(on ? Color.clear : DS.separator))
                }
                .buttonStyle(.plain)
                .help(on ? "Hide \(source.label)'s lines" : "Show \(source.label)'s lines")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }
}

/// Opens logs in their own window.
struct OpenLogsWindowButton: View {
    let target: LogsTarget
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "logs", value: target) } label: {
            Image(systemName: "macwindow.badge.plus")
        }
        .help("Logs in their own window")
        .accessibilityLabel("Open logs in their own window")
    }
}
