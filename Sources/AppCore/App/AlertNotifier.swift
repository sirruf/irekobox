import Foundation
import AppKit
import UserNotifications
import MCPKit
import ContainerKit
import EngineCore
import os

/// Turns the background agent's alerts (a service crashed, a health check
/// failed) into macOS notifications. Polls while the app runs; the last
/// seen alert is remembered, so a relaunch doesn't repeat old ones.
@MainActor
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// What to notify about (Settings › General › Notifications).
    enum Topic: String, CaseIterable {
        case crashes = "notifyCrashes"
        case health = "notifyHealth"

        var enabled: Bool {
            UserDefaults.standard.object(forKey: rawValue) == nil ? true : UserDefaults.standard.bool(forKey: rawValue)
        }

        static func of(_ kind: ContainerAlert.Kind) -> Topic {
            switch kind {
            case .died, .gaveUp: return .crashes
            case .unhealthy, .recovered: return .health
            }
        }
    }

    private static let lastSeenKey = "lastAlertSequence"
    private var lastSeen: UInt64? = {
        let value = UserDefaults.standard.object(forKey: "lastAlertSequence") as? NSNumber
        return value?.uint64Value
    }()
    private var task: Task<Void, Never>?
    /// Asked when a notification is clicked: show this container.
    var onOpen: ((String) -> Void)?
    /// Asked when an image update notification is clicked.
    var onOpenImage: ((String) -> Void)?
    /// An Irekobox update notification was clicked.
    var onAppUpdate: (() -> Void)?
    /// A crash notification's Show Logs.
    var onShowLogs: ((String) -> Void)?
    /// An out-of-memory crash's Give It More Memory.
    var onMoreMemory: ((String) -> Void)?

    static let crashCategory = "container-crash"
    static let memoryCategory = "container-out-of-memory"

    private func registerCategories(_ center: UNUserNotificationCenter) {
        let logs = UNNotificationAction(identifier: "show-logs", title: String(localized: "Show Logs"), options: [.foreground])
        let memory = UNNotificationAction(identifier: "more-memory", title: String(localized: "Give It More Memory"), options: [])
        let allow = UNNotificationAction(identifier: "allow", title: String(localized: "Allow"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "deny", title: String(localized: "Deny"), options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.crashCategory, actions: [logs], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.memoryCategory, actions: [logs, memory], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ])
    }
    /// Container name → health status, from the agent (for list badges).
    private(set) var health: [String: String] = [:]
    var onHealth: (([String: String]) -> Void)?
    private let log = Logger(subsystem: "com.irekobox.app", category: "alerts")

    /// Poll `agent` until `stop()` or the agent is replaced.
    func start(agent: AgentClient) {
        task?.cancel()
        // Tests and previews run without a bundle identifier.
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(agent)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func poll(_ agent: AgentClient) async {
        if let statuses = try? await agent.healthStatuses(), statuses != health {
            health = statuses
            onHealth?(statuses)
        }
        guard let lastSeen else {
            // First run: start from now, never replay history.
            if let (_, latest) = try? await agent.alerts(after: .max) { remember(latest) }
            return
        }
        guard let (alerts, latest) = try? await agent.alerts(after: lastSeen) else { return }
        // A newer agent started its numbering below what we saw: catch up.
        if alerts.isEmpty, latest < lastSeen { remember(latest); return }
        for alert in alerts where Topic.of(alert.kind).enabled {
            await post(alert)
        }
        if let newest = alerts.map(\.sequence).max() { remember(newest) }
    }

    private func remember(_ sequence: UInt64) {
        lastSeen = sequence
        UserDefaults.standard.set(NSNumber(value: sequence), forKey: Self.lastSeenKey)
    }

    static func title(_ alert: ContainerAlert) -> String {
        switch alert.kind {
        case .died: return String(localized: "\(alert.container) crashed")
        case .gaveUp: return String(localized: "\(alert.container) stopped restarting")
        case .unhealthy: return String(localized: "\(alert.container) is unhealthy")
        case .recovered: return String(localized: "\(alert.container) is healthy again")
        }
    }

    private func post(_ alert: ContainerAlert) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        registerCategories(center)
        let content = UNMutableNotificationContent()
        content.title = Self.title(alert)
        content.body = alert.detail
        if alert.kind == .died || alert.kind == .gaveUp {
            content.categoryIdentifier = alert.detail.contains("out of memory") ? Self.memoryCategory : Self.crashCategory
        }
        content.userInfo = ["container": alert.container]
        content.threadIdentifier = alert.container
        if alert.kind != .recovered { content.sound = .default }
        let request = UNNotificationRequest(identifier: "alert-\(alert.sequence)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A newer image is published for a tag in use.
    func notifyImageUpdate(_ reference: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            let name = reference.split(separator: "/").last.map(String.init) ?? reference
            content.title = String(localized: "Update for \(name)")
            content.body = String(localized: "A newer image is published. Pull it, then recreate the containers that use it.")
            content.userInfo = ["image": reference]
            try? await center.add(UNNotificationRequest(identifier: "image-\(reference)", content: content, trigger: nil))
        }
    }

    /// A newer Irekobox is published.
    func notifyAppUpdate(_ version: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Irekobox \(version) is available")
            content.body = String(localized: "Click to see what's new and install it.")
            content.userInfo = ["appUpdate": version]
            try? await center.add(UNNotificationRequest(identifier: "app-update-\(version)", content: content, trigger: nil))
        }
    }

    // MARK: - Assistant approvals

    static let approvalCategory = "assistant-approval"
    /// Requests already shown (the server repeats one while the app starts).
    private var shownApprovals: Set<String> = []

    /// An assistant wants to delete something: ask with Allow and Deny, and
    /// tell its server the answer.
    func askApproval(id: String, assistant: String, action: String) {
        guard shownApprovals.insert(id).inserted else { return }
        Task {
            guard Bundle.main.bundleIdentifier != nil else { return answer(id, false) }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            registerCategories(center)
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else {
                return askInWindow(id: id, assistant: assistant, action: action)
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(assistant) wants to delete")
            content.body = String(localized: "\(Self.sentence(action)). Allow it?")
            content.categoryIdentifier = Self.approvalCategory
            content.userInfo = ["approval": id, "assistant": assistant, "action": action]
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "approval-\(id)", content: content, trigger: nil))
            } catch {
                askInWindow(id: id, assistant: assistant, action: action)
            }
        }
    }

    private func askInWindow(id: String, assistant: String, action: String) {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "\(assistant) wants to delete")
        alert.informativeText = String(localized: "\(Self.sentence(action)).")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Deny"))
        alert.addButton(withTitle: String(localized: "Allow"))
        answer(id, alert.runModal() == .alertSecondButtonReturn)
    }

    /// The requested action with a capital first letter ("Delete the volume db").
    private static func sentence(_ action: String) -> String {
        action.prefix(1).uppercased() + action.dropFirst()
    }

    func answer(_ id: String, _ approved: Bool) {
        DistributedNotificationCenter.default().postNotificationName(AppApprover.response, object: id,
                                                                     userInfo: ["approved": approved],
                                                                     deliverImmediately: true)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let id = info["approval"] as? String {
            let action = response.actionIdentifier
            let assistant = info["assistant"] as? String ?? String(localized: "An assistant")
            let what = info["action"] as? String ?? String(localized: "delete something")
            await MainActor.run {
                switch action {
                case "allow": answer(id, true)
                case "deny", UNNotificationDismissActionIdentifier: answer(id, false)
                default:
                    // The banner itself was clicked: ask in a window.
                    askInWindow(id: id, assistant: assistant, action: what)
                }
            }
            return
        }
        if info["appUpdate"] != nil {
            await MainActor.run { onAppUpdate?() }
            return
        }
        if let image = info["image"] as? String {
            await MainActor.run { onOpenImage?(image) }
            return
        }
        guard let name = info["container"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "show-logs": onShowLogs?(name)
            case "more-memory": onMoreMemory?(name)
            default: onOpen?(name)
            }
        }
    }
}
