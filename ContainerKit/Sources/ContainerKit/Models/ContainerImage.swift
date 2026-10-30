import Foundation

/// A local image from `container image ls --format json`.
/// Named `ContainerImage` to avoid clashing with SwiftUI's `Image`.
public struct ContainerImage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let variants: [Variant]?

    public struct Configuration: Codable, Hashable, Sendable {
        public let name: String
        public let creationDate: String?
        public let descriptor: Descriptor

        public struct Descriptor: Codable, Hashable, Sendable {
            public let digest: String
            public let mediaType: String
            public let size: Int
        }
    }

    public struct Variant: Codable, Hashable, Sendable {
        public let size: Int?
        public let platform: Platform?

        public struct Platform: Codable, Hashable, Sendable {
            public let architecture: String?
            public let os: String?
        }
    }

    /// `docker.io/library/alpine:latest`.
    public var reference: String { configuration.name }
    /// `alpine:latest`.
    public var shortName: String {
        reference.split(separator: "/").last.map(String.init) ?? reference
    }
    public var digest: String { configuration.descriptor.digest }
    /// Sum of variant blob sizes (approximate on-disk content size).
    public var totalSize: Int { (variants ?? []).compactMap(\.size).reduce(0, +) }
    /// Images `container` pulls for itself — the VM init image and the BuildKit
    /// builder — rather than images the user works with.
    public var isSystem: Bool {
        Self.systemPrefixes.contains { reference.hasPrefix($0) }
    }

    static let systemPrefixes = [
        "ghcr.io/apple/containerization/vminit",
        "ghcr.io/apple/container-builder-shim/",
    ]

    /// Distinct architectures across variants (e.g. `arm64`, `amd64`).
    public var architectures: [String] {
        Array(Set((variants ?? []).compactMap { $0.platform?.architecture }.filter { $0 != "unknown" })).sorted()
    }
}
