import Foundation
import Observation
import ContainerKit

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
public final class Settings {
    public static let shared = Settings()

    private enum Keys {
        static let binaryPath = "binaryPath"
        static let pollingInterval = "pollingInterval"
    }

    /// Path to the `container` binary.
    public var binaryPath: String {
        didSet { UserDefaults.standard.set(binaryPath, forKey: Keys.binaryPath) }
    }

    /// Auto-refresh interval for live lists, in seconds.
    public var pollingInterval: Double {
        didSet { UserDefaults.standard.set(pollingInterval, forKey: Keys.pollingInterval) }
    }

    /// Polling interval clamped to a sane range for consumers.
    public var refreshSeconds: Double { min(60, max(1, pollingInterval)) }

    private init() {
        let defaults = UserDefaults.standard
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ContainerCLI.defaultBinaryPath
        let stored = defaults.double(forKey: Keys.pollingInterval)
        pollingInterval = stored == 0 ? 4 : stored
    }
}
