import Foundation
import ContainerKit

/// A kind of engine state the store can fetch and poll.
public enum EngineResource: String, Hashable, Sendable, CaseIterable, Codable {
    /// Service status and the builder.
    case system
    case containers
    case images
    case volumes
    case networks
    case diskUsage
}

/// The last good value of a resource plus the outcome of the latest fetch.
/// A failed fetch keeps the previous value and records the error, so the UI can
/// show stale data with a warning instead of an empty list.
public struct Loadable<Value: Sendable & Codable>: Sendable, Codable {
    public internal(set) var value: Value?
    public internal(set) var error: EngineError?
    /// When `value` was last fetched successfully.
    public internal(set) var updatedAt: Date?

    public init(value: Value? = nil, error: EngineError? = nil, updatedAt: Date? = nil) {
        self.value = value
        self.error = error
        self.updatedAt = updatedAt
    }

    /// A value is shown, but the latest refresh failed.
    public var isStale: Bool { value != nil && error != nil }
}

/// Service state as seen by the store.
public enum ServiceState: Sendable, Equatable, Codable {
    case unknown
    case running(SystemStatus)
    case stopped
    /// Status could not be determined (not the same as stopped).
    case failed(EngineError)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var status: SystemStatus? {
        if case .running(let status) = self { return status }
        return nil
    }
}

/// Everything the store knows, at one point in time.
public struct EngineSnapshot: Sendable, Codable {
    public internal(set) var service: ServiceState = .unknown
    public internal(set) var builder: BuilderStatus?
    public internal(set) var containers = Loadable<[Container]>()
    public internal(set) var images = Loadable<[ContainerImage]>()
    public internal(set) var volumes = Loadable<[Volume]>()
    public internal(set) var networks = Loadable<[Network]>()
    public internal(set) var diskUsage = Loadable<SystemDiskUsage>()

    public init() {}

    /// When `resource` was last fetched successfully.
    public func updatedAt(for resource: EngineResource) -> Date? {
        switch resource {
        case .system: return nil
        case .containers: return containers.updatedAt
        case .images: return images.updatedAt
        case .volumes: return volumes.updatedAt
        case .networks: return networks.updatedAt
        case .diskUsage: return diskUsage.updatedAt
        }
    }

    /// The latest fetch error for `resource`, if any.
    public func error(for resource: EngineResource) -> EngineError? {
        switch resource {
        case .system:
            if case .failed(let error) = service { return error }
            return nil
        case .containers: return containers.error
        case .images: return images.error
        case .volumes: return volumes.error
        case .networks: return networks.error
        case .diskUsage: return diskUsage.error
        }
    }
}

/// A change detected between two snapshots.
public enum EngineEvent: Sendable, Equatable, Codable {
    case servicesStarted
    case servicesStopped
    case containerCreated(id: String)
    case containerRemoved(id: String)
    case containerStateChanged(id: String, from: Container.State, to: Container.State)
    case imageAdded(reference: String)
    case imageRemoved(reference: String)
    case volumeAdded(name: String)
    case volumeRemoved(name: String)
    case networkAdded(name: String)
    case networkRemoved(name: String)
}

/// What subscribers receive: the new snapshot and the events that produced it.
public struct EngineUpdate: Sendable, Codable {
    public let snapshot: EngineSnapshot
    public let events: [EngineEvent]
}
