import AppIntents
import AppCore

/// Brings in the intents that live in AppCore.
struct IrekoboxIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [AppCoreIntents.self] }
}

/// What Spotlight and Shortcuts offer without setup.
struct IrekoboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartProjectIntent(), phrases: [
            "Start \(\.$project) in \(.applicationName)",
            "Start compose project \(\.$project) with \(.applicationName)",
        ], shortTitle: "Start Project", systemImageName: "play.fill")
        AppShortcut(intent: StopProjectIntent(), phrases: [
            "Stop \(\.$project) in \(.applicationName)",
        ], shortTitle: "Stop Project", systemImageName: "stop.fill")
        AppShortcut(intent: OpenProjectIntent(), phrases: [
            "Open \(\.$project) in \(.applicationName)",
        ], shortTitle: "Open Project", systemImageName: "square.stack.3d.up")
        AppShortcut(intent: RestartContainerIntent(), phrases: [
            "Restart \(\.$container) in \(.applicationName)",
        ], shortTitle: "Restart Container", systemImageName: "arrow.clockwise")
        AppShortcut(intent: ShowLogsIntent(), phrases: [
            "Show logs of \(\.$container) in \(.applicationName)",
        ], shortTitle: "Show Logs", systemImageName: "text.alignleft")
        AppShortcut(intent: RunImageIntent(), phrases: [
            "Run a container with \(.applicationName)",
        ], shortTitle: "Run Container", systemImageName: "shippingbox")
    }
}
