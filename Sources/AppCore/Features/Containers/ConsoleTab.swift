import SwiftUI
import AppKit
import SwiftTerm
import ContainerKit

/// Which shell to open in the container.
enum ConsoleShell: String, CaseIterable, Identifiable {
    /// bash when the image has it, otherwise sh.
    case auto = "Auto"
    case sh, bash, ash, zsh

    var id: String { rawValue }

    /// The picker's name for it.
    var title: String {
        self == .auto ? String(localized: "Auto", comment: "Shell picker: bash when the image has it, else sh") : rawValue
    }

    /// Arguments for `container` that open this shell interactively.
    func arguments(containerID: String) -> [String] {
        let base = ["exec", "--interactive", "--tty"] + TerminalEnvironment.flags + [containerID]
        switch self {
        case .auto:
            return base + ["sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"]
        case .sh, .bash, .ash, .zsh:
            return base + [rawValue]
        }
    }

    /// What the user would type for the same session.
    func displayCommand(containerID: String) -> String {
        switch self {
        case .auto: return "container exec -it \(containerID) sh   # " + String(localized: "bash when available")
        default: return "container exec -it \(containerID) \(rawValue)"
        }
    }
}

/// Interactive shell into a running container via `container exec -it`, in a
/// PTY-backed terminal (SwiftTerm). The session belongs to this view: leaving
/// the tab, closing the window or stopping the container ends the process.
struct ConsoleTab: View {
    let container: Container
    /// Whether the Console tab is selected. The terminal (and `container exec`)
    /// is created only once this first becomes true.
    let isActive: Bool

    @State private var shell: ConsoleShell = .auto
    @State private var session = UUID()
    @State private var hasActivated = false
    @State private var ended: Int32??

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !container.state.isRunning {
                ContentUnavailableView("Container Not Running", systemImage: "pause.circle",
                                       description: Text("Start the container to open a shell."))
            } else if let exit = ended {
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
                .accessibilityIdentifier("console.ended")
            } else if hasActivated {
                ContainerTerminalView(binaryPath: Settings.shared.binaryPath,
                                      arguments: shell.arguments(containerID: container.id),
                                      onExit: { code in ended = .some(code) })
                    .id(session)   // a new session per shell change / reconnect
                    .accessibilityIdentifier("console.terminal")
            } else {
                ContentUnavailableView("Console", systemImage: "terminal",
                                       description: Text("Opens a shell when you switch to this tab."))
            }
        }
        .onAppear { if isActive { hasActivated = true } }
        .onChange(of: isActive) { _, active in if active { hasActivated = true } }
        .onChange(of: shell) { _, _ in reconnect() }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.m) {
            Picker("Shell", selection: $shell) {
                ForEach(ConsoleShell.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("console.shell")

            Text(shell.displayCommand(containerID: container.id))
                .font(DS.Font.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            OpenTerminalWindowButton(target: TerminalTarget(
                title: container.id, command: shell.displayCommand(containerID: container.id),
                arguments: shell.arguments(containerID: container.id)))
                .disabled(!container.state.isRunning)
            Button { reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                .disabled(!container.state.isRunning)
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private func reconnect() {
        ended = nil
        session = UUID()
    }
}

/// Wraps SwiftTerm's `LocalProcessTerminalView`, running the `container` CLI in
/// a pseudo-terminal so the in-container shell is fully interactive.
struct ContainerTerminalView: NSViewRepresentable {
    let binaryPath: String
    let arguments: [String]
    var dark = false
    let onExit: (Int32?) -> Void

    init(binaryPath: String, arguments: [String], dark: Bool = false, onExit: @escaping (Int32?) -> Void) {
        self.binaryPath = binaryPath
        self.arguments = arguments
        self.dark = dark
        self.onExit = onExit
    }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Dark where it sits in a card (the machine page), the system's colours elsewhere.
        terminal.nativeForegroundColor = dark ? NSColor(white: 0.86, alpha: 1) : .textColor
        terminal.nativeBackgroundColor = dark ? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1) : .textBackgroundColor
        terminal.startProcess(executable: binaryPath, args: arguments, environment: nil, execName: nil)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
    }

    /// The view is going away: end the session so no `container exec` lingers.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.ending = true
        let pid = nsView.process.shellPid
        nsView.terminate()
        if pid > 0 { reap(pid) }
    }

    /// SwiftTerm's `terminate()` sends SIGTERM and stops watching the child, so
    /// nobody would collect it: wait for it (up to 2 s), SIGKILL if needed, and
    /// reap it so it doesn't stay a zombie until the app quits.
    nonisolated static func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<40 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }   // reaped, or not our child
                usleep(50_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    /// Exit code from a raw `wait()` status; a signal reads as 128 + signal, as in shells.
    nonisolated static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// SwiftTerm reports the exit from its own queue; state is lock-protected
    /// and `onExit` always runs on the main thread.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _onExit: (Int32?) -> Void
        private var _ending = false

        init(onExit: @escaping (Int32?) -> Void) {
            _onExit = onExit
        }

        var onExit: (Int32?) -> Void {
            get { lock.withLock { _onExit } }
            set { lock.withLock { _onExit = newValue } }
        }

        /// Set while we end the session ourselves, so that isn't reported as an exit.
        var ending: Bool {
            get { lock.withLock { _ending } }
            set { lock.withLock { _ending = newValue } }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !ending else { return }
            let code = exitCode.map(ContainerTerminalView.exitCode(fromWaitStatus:))
            DispatchQueue.main.async { [self] in onExit(code) }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
