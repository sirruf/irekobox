import Foundation

/// Images a machine can boot. The machine's own init sets up the account,
/// then runs the image's `/sbin/init`; Docker Hub's distribution images
/// (ubuntu, debian, fedora) are made for containers and have none, so the
/// machine stops at once. For those, a local image with systemd is built
/// once from the original and used instead. Alpine's busybox init works.
public enum MachineImage {
    public enum Family: Sendable, Equatable {
        /// Boots as is.
        case ready
        /// systemd added with apt-get.
        case apt
        /// systemd added with dnf.
        case dnf
        /// Unknown: tried as is.
        case unknown
    }

    /// What the machine log says when the image has no init.
    public static let noInitMarker = "/sbin/init: not found"

    /// `docker.io/library/ubuntu:24.04` → ("ubuntu", "24.04").
    static func nameAndTag(_ image: String) -> (name: String, tag: String) {
        let reference = image.split(separator: "@").first.map(String.init) ?? image
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        let parts = last.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts[0].lowercased(), parts.count > 1 ? parts[1] : "latest")
    }

    /// Docker Hub repositories a machine boots, with what each is.
    public static let distributions: [(name: String, about: String)] = [
        ("ubuntu", "Ubuntu"), ("debian", "Debian"), ("fedora", "Fedora"), ("alpine", "Alpine Linux"),
        ("rockylinux", "Rocky Linux"), ("almalinux", "AlmaLinux"), ("oraclelinux", "Oracle Linux"),
    ]

    public static func family(of image: String) -> Family {
        switch nameAndTag(image).name {
        case "alpine": return .ready
        case "ubuntu", "debian": return .apt
        case "fedora", "rockylinux", "almalinux", "centos", "oraclelinux": return .dnf
        default: return .unknown
        }
    }

    /// Whether Irekobox builds a machine image for it.
    public static func needsPreparing(_ image: String) -> Bool {
        let family = family(of: image)
        return family == .apt || family == .dnf
    }

    /// The local image built from `image` (`irekobox-machine-ubuntu:24.04`).
    public static func preparedTag(for image: String) -> String {
        let (name, tag) = nameAndTag(image)
        return "irekobox-machine-\(name):\(tag)"
    }

    /// The Dockerfile that adds systemd (and sudo) to `image`.
    public static func dockerfile(for image: String) -> String? {
        switch family(of: image) {
        case .apt:
            return """
            FROM \(image)
            RUN apt-get update \\
             && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd systemd-sysv sudo ca-certificates \\
             && rm -rf /var/lib/apt/lists/*
            """
        case .dnf:
            return """
            FROM \(image)
            RUN dnf install -y systemd sudo && dnf clean all
            """
        case .ready, .unknown:
            return nil
        }
    }
}
