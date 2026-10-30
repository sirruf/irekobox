import Foundation
import ServiceManagement
import EngineCore

/// The root helper that points `/var/run/docker.sock` at our socket
/// (`SMAppService.daemon`; the user approves it once in System Settings).
@MainActor
enum SocketLinkHelper {
    static let plistName = SocketLink.helperLabel + ".plist"

    private static var service: SMAppService { .daemon(plistName: plistName) }

    enum State: Equatable {
        case off
        case needsApproval
        case on(SocketLink.Status)
        case failed(String)
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func state() -> State {
        guard SocketLink.requested() else { return .off }
        switch service.status {
        case .enabled: return .on(SocketLink.status(home: home))
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    static func enable() -> State {
        do {
            try SocketLink.request(true)
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return .needsApproval
            }
            return .failed(error.localizedDescription)
        }
        return state()
    }

    /// Ask for the old link back, give the helper a moment to restore it,
    /// then remove the helper.
    static func disable() async -> State {
        do {
            try SocketLink.request(false)
        } catch {
            return .failed(error.localizedDescription)
        }
        if service.status == .enabled {
            for _ in 0..<20 where SocketLink.status(home: home) == .ours {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        try? await service.unregister()
        return .off
    }

    static func openApproval() { SMAppService.openSystemSettingsLoginItems() }
}
