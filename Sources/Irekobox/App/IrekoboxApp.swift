import SwiftUI
import AppKit
import AppCore
import AppIntents

@main
struct IrekoboxApp: App {
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        // Shortcuts and Spotlight act on the same state as the windows.
        AppDependencyManager.shared.add(dependency: state)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    Branding.applyDockIcon()
                    await appState.refreshSystemAtLaunch()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            NavigationCommands(app: appState)
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
            // Our own About window: facts plus engine, agent and Docker API status.
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
                if appState.appUpdatesAvailable {
                    Button("Check for Updates…") {
                        Task { await appState.appUpdater.checkIfDue(force: true) }
                        appState.openSettings()
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { appState.requestRefresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Not "Services": that is the system's submenu of the app menu.
            CommandMenu("Engine") {
                Button("Start Engine") { Task { await appState.startServices() } }
                    .disabled(appState.servicesRunning)
                Button("Stop Engine") { Task { await appState.stopServices() } }
                    .disabled(!appState.servicesRunning)
            }
            // Help links.
            CommandGroup(replacing: .help) {
                Link("Apple container on GitHub",
                     destination: URL(string: "https://github.com/apple/container")!)
                Link("Install / Releases",
                     destination: URL(string: "https://github.com/apple/container/releases")!)
            }
        }

        Window("About \(Brand.name)", id: "about") {
            AboutView()
                .environment(appState)
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        // Terminals of containers, machines and pods in their own windows.
        WindowGroup("Terminal", id: "terminal", for: TerminalTarget.self) { $target in
            TerminalWindow(target: target)
                .environment(appState)
        }
        .defaultSize(width: 900, height: 560)
        .restorationBehavior(.disabled)

        // A project's logs, or its compose file, in their own windows.
        WindowGroup("Logs", id: "logs", for: LogsTarget.self) { $target in
            LogsWindow(target: target)
                .environment(appState)
        }
        .defaultSize(width: 860, height: 480)
        .restorationBehavior(.disabled)

        WindowGroup("Compose File", id: "compose-file", for: String.self) { $name in
            ComposeFileWindow(name: name)
                .environment(appState)
        }
        .defaultSize(width: 700, height: 520)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel(running: appState.servicesRunning, windowRequest: appState.mainWindowRequest,
                         aboutRequest: appState.aboutWindowRequest)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// The status-item icon. It exists on every launch, so it also makes sure the
/// launch ends with a main window: AppKit skips creating the untitled one for
/// some launch paths (XCUITest launches since macOS 27.2), which left only
/// the menu bar extra.
private struct MenuBarLabel: View {
    let running: Bool
    /// Changes when something (a notification) asks for the main window.
    let windowRequest: Int
    /// Changes when an update notification asks for the About window.
    let aboutRequest: Int
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: running ? "shippingbox.fill" : "shippingbox")
            .task {
                try? await Task.sleep(for: .seconds(1))
                let hasMain = NSApplication.shared.windows.contains {
                    $0.identifier?.rawValue.hasPrefix("main") == true
                }
                if !hasMain {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
            }
            .onChange(of: windowRequest) {
                NSApplication.shared.activate()
                let windows = NSApplication.shared.windows.filter {
                    $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain
                }
                if windows.isEmpty { openWindow(id: "main") }
                windows.forEach { $0.makeKeyAndOrderFront(nil) }
            }
            .onChange(of: aboutRequest) {
                openWindow(id: "about")
                NSApplication.shared.activate()
            }
    }
}

/// App menu › About Irekobox: opens the About window.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(Brand.name)") { openWindow(id: "about") }
    }
}
