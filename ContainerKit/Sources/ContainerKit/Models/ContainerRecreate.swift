import Foundation

/// The editable parts of a container for "Edit & Recreate".
public struct ContainerEdits: Sendable, Hashable {
    public var environment: [String]   // "KEY=VALUE"
    public var ports: [String]         // "[ip:]host:container[/proto]"
    public var volumes: [String]       // "source:destination[:ro]"
    public var networks: [String]      // network names
    /// New limits; nil keeps the container's own.
    public var cpus: Int?
    public var memoryMiB: Int64?

    public init(environment: [String] = [], ports: [String] = [],
                volumes: [String] = [], networks: [String] = [], cpus: Int? = nil, memoryMiB: Int64? = nil) {
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.cpus = cpus
        self.memoryMiB = memoryMiB
    }
}

/// Pure builder for the `container run` argv used to recreate a container with
/// edited settings, preserving image, name, command, resources, and CWD.
public enum ContainerRecreate {
    /// Edits pre-filled from the container's current configuration.
    public static func currentEdits(for container: Container) -> ContainerEdits {
        let config = container.configuration
        return ContainerEdits(
            environment: config.initProcess.environment,
            ports: (config.publishedPorts ?? []).map(\.runSpec),
            volumes: (config.mounts ?? []).compactMap(\.runSpec),
            networks: config.networks.map(\.network)
        )
    }

    /// The image's default entrypoint, parsed from `container image inspect`.
    /// Needed because `container run <image> <args>` *prepends* the image
    /// entrypoint to `<args>` — so we must strip it from the inspected command
    /// to avoid accumulating the entrypoint on each recreate.
    public static func parseEntrypoint(_ data: Data, architecture: String) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = array.first as? [String: Any],
              let variants = first["variants"] as? [[String: Any]] else { return [] }

        func entrypoint(_ v: [String: Any]) -> [String]? {
            ((v["config"] as? [String: Any])?["config"] as? [String: Any])?["Entrypoint"] as? [String]
        }
        func arch(_ v: [String: Any]) -> String? {
            (v["config"] as? [String: Any])?["architecture"] as? String
        }
        if let match = variants.first(where: { arch($0) == architecture }), let ep = entrypoint(match) {
            return ep
        }
        return variants.lazy.compactMap(entrypoint).first ?? []
    }

    /// `container run …` argv reproducing `container` with `edits` applied.
    /// `imageEntrypoint` (from ``parseEntrypoint``) is stripped from the command.
    public static func runArguments(for container: Container, edits: ContainerEdits,
                                    imageEntrypoint: [String] = []) -> [String] {
        let config = container.configuration
        var args = ["run", "--detach", "--name", config.id]

        for network in edits.networks where !network.isEmpty {
            args += ["--network", network]
        }
        for env in edits.environment where !env.isEmpty {
            args += ["--env", env]
        }
        for port in edits.ports where !port.isEmpty {
            args += ["--publish", port]
        }
        for volume in edits.volumes where !volume.isEmpty {
            args += ["--volume", volume]
        }

        args += ["--cpus", "\(edits.cpus ?? config.resources.cpus)"]
        let mib = edits.memoryMiB ?? max(1, config.resources.memoryInBytes / (1024 * 1024))
        args += ["--memory", "\(mib)M"]

        let cwd = config.initProcess.workingDirectory
        if !cwd.isEmpty && cwd != "/" { args += ["--workdir", cwd] }
        if config.readOnly { args.append("--read-only") }

        // Image + command. `container run <image> <args>` *prepends* the image
        // entrypoint to <args>, so strip the entrypoint prefix from the
        // inspected command to avoid accumulating it across recreates.
        args.append(config.image.reference)
        let fullCommand = [config.initProcess.executable] + config.initProcess.arguments
        if !imageEntrypoint.isEmpty && fullCommand.starts(with: imageEntrypoint) {
            args += fullCommand.dropFirst(imageEntrypoint.count)
        } else {
            args += fullCommand
        }
        return args
    }
}
