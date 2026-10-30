import Foundation

/// `container image inspect` (1.6.1): the image index plus, per platform
/// variant, its OCI image config.
public struct ImageDetails: Codable, Hashable, Sendable {
    public let id: String
    public let configuration: ContainerImage.Configuration
    public let variants: [Variant]

    public struct Variant: Codable, Hashable, Sendable {
        public let digest: String?
        public let size: Int?
        public let platform: ContainerImage.Variant.Platform?
        public let config: OCIConfig?
    }

    /// The OCI image configuration (`application/vnd.oci.image.config.v1+json`).
    public struct OCIConfig: Codable, Hashable, Sendable {
        public let architecture: String?
        public let os: String?
        public let created: String?
        public let author: String?
        public let config: Process?
        public let rootfs: RootFS?
        public let history: [History]?

        public struct Process: Codable, Hashable, Sendable {
            public let Cmd: [String]?
            public let Entrypoint: [String]?
            public let Env: [String]?
            public let WorkingDir: String?
            public let User: String?
            public let ExposedPorts: [String: [String: String]]?
            public let Volumes: [String: [String: String]]?
            public let Labels: [String: String]?
            public let StopSignal: String?
        }

        public struct RootFS: Codable, Hashable, Sendable {
            public let type: String?
            public let diff_ids: [String]?
        }

        public struct History: Codable, Hashable, Sendable {
            public let created: String?
            public let created_by: String?
            public let comment: String?
            public let empty_layer: Bool?
        }
    }

    /// The variant for `architecture` (default: this Mac's), skipping
    /// attestation manifests (`unknown/unknown`).
    public func variant(for architecture: String = "arm64") -> Variant? {
        let real = variants.filter { $0.platform?.architecture != "unknown" && $0.config != nil }
        return real.first { $0.platform?.architecture == architecture } ?? real.first
    }
}
