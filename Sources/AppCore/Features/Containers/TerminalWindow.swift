import SwiftUI

/// A shell session to open in its own window: a container's, a machine's
/// or a pod's (the `container` arguments that start it).
public struct TerminalTarget: Codable, Hashable, Sendable {
    public let title: String
    /// The equivalent command, shown under the title.
    public let command: String
    public let arguments: [String]
    /// Each window its own session: the same shell opened twice gives two
    /// windows (SwiftUI brings back the window of an equal value).
    public var instance = UUID()

    public init(title: String, command: String, arguments: [String]) {
        self.title = title
        self.command = command
        self.arguments = arguments
    }

    /// The same shell, for another tab.
    func another() -> TerminalTarget {
        var copy = self
        copy.instance = UUID()
        return copy
    }
}

/// A terminal window: dark, resizable, joining other terminal windows as
/// tabs like Terminal.app (⌘T opens another). A shell that drops because
/// its container restarted reconnects by itself; `exit` ends the session.
public struct TerminalWindow: View {
    let target: TerminalTarget?
    @State private var session = UUID()
    @State private var ended: Int32??
    @State private var reconnecting = false
    @State private var attempts = 0
    @Environment(\.openWindow) private var openWindow

    public init(target: TerminalTarget?) {
        self.target = target
    }

    private static let background = Color(red: 0.12, green: 0.12, blue: 0.13)

    public var body: some View {
        Group {
            if let target {
                VStack(spacing: 0) {
                    if let exit = ended, !reconnecting {
                        ContentUnavailableView {
                            Label("Session ended", systemImage: "terminal")
                        } description: {
                            if let code = exit {
                                Text("The shell exited with code \(String(code)).")
                            } else {
                                Text("The shell exited.")
                            }
                        } actions: {
                            Button("Reconnect") { reconnect() }.buttonStyle(.borderedProminent)
                        }
                        .foregroundStyle(.white)
                    } else {
                        ContainerTerminalView(binaryPath: Settings.shared.binaryPath, arguments: target.arguments, dark: true,
                                              onExit: { code in dropped(code) })
                            .id(session)
                            .padding(.leading, DS.Spacing.s)
                    }
                    statusBar(target)
                }
                .background(Self.background)
                .navigationTitle("Terminal — \(target.title)")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { openWindow(id: "terminal", value: target.another()) } label: {
                            Label("New Tab", systemImage: "plus")
                        }
                            .keyboardShortcut("t")
                            .help("Another shell in \(target.title), as a tab")
                    }
                }
                .background(TabbingWindow(identifier: "terminal"))
            } else {
                ContentUnavailableView("No Session", systemImage: "terminal")
            }
        }
        .frame(minWidth: 480, minHeight: 280)
        .preferredColorScheme(.dark)
    }

    private func statusBar(_ target: TerminalTarget) -> some View {
        HStack(spacing: DS.Spacing.m) {
            HStack(spacing: 5) {
                Circle().fill(ended == nil ? Color.green : reconnecting ? .orange : .gray).frame(width: 7, height: 7)
                Text(ended == nil ? "connected" : reconnecting ? "reconnecting…" : "ended")
            }
            Text(verbatim: "UTF-8")
            Spacer()
            Text("Reconnects automatically if restarted")
                .help(target.command)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, DS.Spacing.m)
        .frame(height: 26)
        .background(Color.black.opacity(0.25))
    }

    /// `exit` (code 0) ends the session; anything else, such as the container
    /// restarting under the shell, retries for about half a minute.
    private func dropped(_ code: Int32?) {
        ended = .some(code)
        guard code != 0, attempts < 15 else {
            reconnecting = false
            return
        }
        reconnecting = true
        attempts += 1
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard reconnecting else { return }
            ended = nil
            session = UUID()
            // Counted as a success once the shell has stayed up a while.
            try? await Task.sleep(for: .seconds(10))
            if ended == nil { attempts = 0; reconnecting = false }
        }
    }

    private func reconnect() {
        attempts = 0
        reconnecting = false
        ended = nil
        session = UUID()
    }
}

/// Makes the hosting window join others with the same identifier as tabs.
private struct TabbingWindow: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.tabbingIdentifier = identifier
            view.window?.tabbingMode = .preferred
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// "Open in New Window" for a terminal tab.
struct OpenTerminalWindowButton: View {
    let target: TerminalTarget
    var title: LocalizedStringKey = "Open in New Window"
    var systemImage = "macwindow.badge.plus"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "terminal", value: target) } label: {
            Label(title, systemImage: systemImage)
        }
        .help("A terminal in its own window")
    }
}
