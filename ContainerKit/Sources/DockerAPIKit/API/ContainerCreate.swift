import Foundation
import ContainerKit

/// `POST /containers/create` body (the subset clients send), decoded leniently.
struct CreateRequest: Decodable {
    /// Docker's "strslice": a JSON array or a single string.
    struct StringList: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let list = try? container.decode([String].self) {
                values = list
            } else {
                values = [try container.decode(String.self)]
            }
        }
    }

    struct HealthConfig: Codable, Equatable {
        let Test: [String]?
        let Interval: Int64?
        let Timeout: Int64?
        let Retries: Int?
        let StartPeriod: Int64?
        let StartInterval: Int64?
    }

    struct PortBinding: Decodable {
        let HostIp: String?
        let HostPort: String?
    }

    struct Mount: Decodable {
        let `Type`: String?
        let Source: String?
        let Target: String?
        let ReadOnly: Bool?
    }

    struct Ulimit: Decodable {
        let Name: String
        let Soft: Int64
        let Hard: Int64
    }

    struct RestartPolicy: Decodable {
        let Name: String?
        let MaximumRetryCount: Int?
    }

    struct LogConfig: Decodable {
        let `Type`: String?
    }

    struct HostConfig: Decodable {
        let Binds: [String]?
        let Mounts: [Mount]?
        let Tmpfs: [String: String]?
        let PortBindings: [String: [PortBinding]?]?
        let PublishAllPorts: Bool?
        let NetworkMode: String?
        let RestartPolicy: RestartPolicy?
        let AutoRemove: Bool?
        let Memory: Int64?
        let NanoCpus: Int64?
        let CpuCount: Int64?
        let CpuQuota: Int64?
        let CpuPeriod: Int64?
        let CpuShares: Int64?
        let CapAdd: [String]?
        let CapDrop: [String]?
        let ReadonlyRootfs: Bool?
        let Dns: [String]?
        let DnsSearch: [String]?
        let DnsOptions: [String]?
        let Ulimits: [Ulimit]?
        let Init: Bool?
        let ShmSize: Int64?
        let Privileged: Bool?
        let Devices: [AnyDecodable]?
        let DeviceRequests: [AnyDecodable]?
        let Sysctls: [String: String]?
        let PidMode: String?
        let IpcMode: String?
        let UsernsMode: String?
        let ExtraHosts: [String]?
        let SecurityOpt: [String]?
        let LogConfig: LogConfig?
    }

    struct EndpointConfig: Decodable {
        let Aliases: [String]?
        let MacAddress: String?
    }

    struct NetworkingConfig: Decodable {
        let EndpointsConfig: [String: EndpointConfig?]?
    }

    let Image: String?
    let Cmd: StringList?
    let Entrypoint: StringList?
    let Env: [String]?
    let WorkingDir: String?
    let User: String?
    let Labels: [String: String]?
    let Tty: Bool?
    let OpenStdin: Bool?
    let Hostname: String?
    let Domainname: String?
    let ExposedPorts: [String: AnyDecodable]?
    let Volumes: [String: AnyDecodable]?
    let StopSignal: String?
    let StopTimeout: Int?
    let Healthcheck: HealthConfig?
    let HostConfig: HostConfig?
    let NetworkingConfig: NetworkingConfig?
}

/// Accepts any JSON value (for fields whose content we only test for presence).
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

/// Labels that keep Docker settings `container` has no flag for, so they
/// live with the container (the supervisor reads them, 2.4).
public enum DockerLabels {
    public static let restartPolicy = "com.irekobox.docker.restart"
    public static let stopSignal = "com.irekobox.docker.stop-signal"
    public static let stopTimeout = "com.irekobox.docker.stop-timeout"
    public static let healthcheck = "com.irekobox.docker.healthcheck"
    public static let anonymousVolumes = "com.irekobox.docker.anonymous-volumes"
    /// Network aliases as JSON `{"network": ["alias", …]}`, served through
    /// /etc/hosts by ``HostsSync`` (the runtime's DNS doesn't resolve them).
    public static let aliases = "com.irekobox.docker.aliases"
    /// `docker run --rm`: a failed start removes the container, as in Docker.
    public static let autoRemove = "com.irekobox.docker.auto-remove"
    /// The Docker name of a container whose name is too long for the runtime.
    public static let name = "com.irekobox.docker.name"
    /// A volume's `sync` driver option (`full`, `fsync`, `nosync`), applied
    /// where it is mounted.
    public static let volumeSync = "com.irekobox.docker.volume-sync"
}

/// Docker create request → `container create` arguments.
enum CreateMapping {
    struct Result: Equatable {
        var arguments: [String]
        var warnings: [String]
        /// Anonymous volumes to create first: (volume name, mount path).
        var anonymousVolumes: [(name: String, path: String)]
        /// Every volume mount, named or anonymous: (volume name, mount path).
        var volumeMounts: [(name: String, path: String)] = []
        var image = ""

        static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.arguments == rhs.arguments && lhs.warnings == rhs.warnings
                && lhs.anonymousVolumes.map { "\($0.name):\($0.path)" } == rhs.anonymousVolumes.map { "\($0.name):\($0.path)" }
        }
    }

    /// - Parameter freePort: a free host port, for bindings without one.
    /// `dnsName`: a name under the local domain for the first network (a
    /// compose service's `web.shop.test`), registered as a runtime alias.
    /// `dockerSocket`: our API's socket, given to a container that mounts
    /// the Docker socket. `volumeSync`: sync modes of named volumes, by name.
    static func arguments(_ request: CreateRequest, name: String, platform: String?, dnsName: String? = nil,
                          dockerSocket: String? = nil, volumeSync: [String: String] = [:],
                          freePort: () throws -> Int) throws -> Result {
        guard let image = request.Image, !image.isEmpty else {
            throw DockerAPIError.badParameter("config cannot be empty in order to create a container")
        }
        let host = request.HostConfig
        try refuseUnsupported(request)

        let dockerName = name
        let name = ContainerNames.runtimeName(for: dockerName)
        var args = ["--name", name]
        var warnings: [String] = []
        var labels = request.Labels ?? [:]
        if name != dockerName { labels[DockerLabels.name] = dockerName }

        if let platform, !platform.isEmpty { args += ["--platform", platform] }
        for entry in request.Env ?? [] { args += ["-e", entry] }
        if let dir = request.WorkingDir, !dir.isEmpty { args += ["-w", dir] }
        if let user = request.User, !user.isEmpty { args += ["-u", user] }
        if request.Tty == true { args.append("-t") }
        if request.OpenStdin == true { args.append("-i") }

        // Settings without a flag, kept as labels.
        if let policy = host?.RestartPolicy, let policyName = policy.Name, !policyName.isEmpty, policyName != "no" {
            let retries = policy.MaximumRetryCount ?? 0
            labels[DockerLabels.restartPolicy] = policyName == "on-failure" && retries > 0
                ? "on-failure:\(retries)" : policyName
            warnings.append("Restart policy \"\(policyName)\" is recorded; Irekobox's supervisor applies it while it runs.")
        }
        if let signal = request.StopSignal, !signal.isEmpty { labels[DockerLabels.stopSignal] = signal }
        if let timeout = request.StopTimeout { labels[DockerLabels.stopTimeout] = String(timeout) }
        if let health = request.Healthcheck, let test = health.Test, test.first != "NONE",
           let data = try? JSONEncoder().encode(health) {
            labels[DockerLabels.healthcheck] = String(decoding: data, as: UTF8.self)
        }

        // Mounts.
        var anonymous: [(String, String)] = []
        var volumeMounts: [(String, String)] = []
        for bind in host?.Binds ?? [] {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, parts[1] == dockerSocketTarget {
                args += try dockerSocketMount(dockerSocket)
                continue
            }
            var spec = try bindSpec(bind)
            if parts.count >= 2, !parts[0].hasPrefix("/"), !parts[0].hasPrefix(".") {
                volumeMounts.append((parts[0], parts[1]))
                if let sync = volumeSync[parts[0]] { spec += (spec.hasSuffix(":ro") ? "," : ":") + "sync=\(sync)" }
            }
            args += ["-v", spec]
        }
        for mount in host?.Mounts ?? [] {
            guard let target = mount.Target, !target.isEmpty else {
                throw DockerAPIError.badParameter("invalid mount config: Target is required")
            }
            if (mount.Type ?? "").lowercased() == "bind", target == dockerSocketTarget {
                args += try dockerSocketMount(dockerSocket)
                continue
            }
            // `--mount type=bind` takes folders only; `-v` takes a single
            // file too (Compose secrets arrive as such mounts).
            if (mount.Type ?? "").lowercased() == "bind", let source = mount.Source, isFile(source) {
                args += ["-v", "\(source):\(target)" + (mount.ReadOnly == true ? ":ro" : "")]
                continue
            }
            switch (mount.Type ?? "volume").lowercased() {
            case "bind", "volume":
                var spec = "type=\(mount.Type?.lowercased() ?? "volume"),target=\(target)"
                if let source = mount.Source, !source.isEmpty {
                    spec = "type=\(mount.Type?.lowercased() ?? "volume"),source=\(source),target=\(target)"
                    if (mount.Type ?? "volume").lowercased() == "volume" {
                        volumeMounts.append((source, target))
                        if let sync = volumeSync[source] { spec += ",sync=\(sync)" }
                    }
                } else if (mount.Type ?? "volume").lowercased() == "volume" {
                    let volume = anonymousVolumeName(container: name, path: target)
                    anonymous.append((volume, target))
                    volumeMounts.append((volume, target))
                    spec = "type=volume,source=\(volume),target=\(target)"
                }
                if mount.ReadOnly == true { spec += ",readonly" }
                args += ["--mount", spec]
            case "tmpfs":
                args += ["--tmpfs", target]
            default:
                throw DockerAPIError.badParameter("mount type \"\(mount.Type ?? "")\" is not supported by Irekobox")
            }
        }
        for path in (host?.Tmpfs ?? [:]).keys.sorted() { args += ["--tmpfs", path] }
        let mounted = Set((host?.Binds ?? []).compactMap { $0.split(separator: ":").dropFirst().first.map(String.init) }
                          + (host?.Mounts ?? []).compactMap(\.Target))
        for path in (request.Volumes ?? [:]).keys.sorted() where !mounted.contains(path) {
            let volume = anonymousVolumeName(container: name, path: path)
            anonymous.append((volume, path))
            volumeMounts.append((volume, path))
            args += ["-v", "\(volume):\(path)"]
        }
        if !anonymous.isEmpty {
            labels[DockerLabels.anonymousVolumes] = anonymous.map(\.0).joined(separator: ",")
        }

        // Ports.
        var published = Set<String>()
        for key in (host?.PortBindings ?? [:]).keys.sorted() {
            let (port, proto) = try containerPort(key)
            let bindings = (host?.PortBindings?[key] ?? nil) ?? [CreateRequest.PortBinding(HostIp: nil, HostPort: nil)]
            for binding in bindings.isEmpty ? [CreateRequest.PortBinding(HostIp: nil, HostPort: nil)] : bindings {
                // Empty or "0": any free port (Testcontainers sends "0").
                let hostPort = try binding.HostPort.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } ?? String(freePort())
                guard !hostPort.contains("-") else {
                    throw DockerAPIError.badParameter("host port ranges are not supported: \(hostPort)")
                }
                var spec = ""
                if let ip = binding.HostIp, !ip.isEmpty, ip != "0.0.0.0", ip != "::" { spec += "\(ip):" }
                spec += "\(hostPort):\(port)"
                if proto != "tcp" { spec += "/\(proto)" }
                args += ["-p", spec]
                published.insert(key)
            }
        }
        if host?.PublishAllPorts == true {
            for key in (request.ExposedPorts ?? [:]).keys.sorted() where !published.contains(key) {
                let (port, proto) = try containerPort(key)
                args += ["-p", "\(try freePort()):\(port)" + (proto == "tcp" ? "" : "/\(proto)")]
            }
        }

        // Networks.
        let endpoints = (request.NetworkingConfig?.EndpointsConfig ?? [:])
        let mode = host?.NetworkMode ?? ""
        var networks: [(String, CreateRequest.EndpointConfig?)] = []
        switch mode {
        case "", "default", "bridge":
            if endpoints.isEmpty { networks = [("default", nil)] }
        case "none":
            args += ["--network", "none"]
        case "host":
            throw DockerAPIError.badParameter("network mode \"host\" is not supported: each container runs in its own VM")
        default:
            if mode.hasPrefix("container:") {
                throw DockerAPIError.badParameter("network mode \"\(mode)\" is not supported: containers can't share a network stack")
            }
            networks = [(mode, endpoints[mode] ?? nil)]
        }
        if mode != "none" {
            for key in endpoints.keys.sorted() where !networks.contains(where: { $0.0 == key }) {
                networks.append((key == "bridge" ? "default" : key, endpoints[key] ?? nil))
            }
        }
        // Aliases aren't given to the runtime: in 1.6 they don't resolve, are
        // global across networks and need a DNS domain. HostsSync writes them
        // into the /etc/hosts of the containers sharing the network instead.
        var aliases: [String: [String]] = [:]
        for (index, (network, endpoint)) in networks.enumerated() {
            var spec = network
            if index == 0, network != "none", let dnsName { spec += ",alias=\(dnsName)" }
            let names = (endpoint?.Aliases ?? []).filter { $0 != name && !$0.isEmpty }
            if !names.isEmpty { aliases[network] = names }
            if let mac = endpoint?.MacAddress, !mac.isEmpty { spec += ",mac=\(mac)" }
            args += ["--network", spec]
        }
        if !aliases.isEmpty, let data = try? JSONEncoder.sorted.encode(aliases) {
            labels[DockerLabels.aliases] = String(decoding: data, as: UTF8.self)
        }

        // Resources.
        if let memory = host?.Memory, memory > 0 {
            args += ["-m", "\((memory + (1 << 20) - 1) >> 20)M"]
        }
        var cpus: Int64?
        if let nano = host?.NanoCpus, nano > 0 { cpus = (nano + 999_999_999) / 1_000_000_000 }
        if let count = host?.CpuCount, count > 0 { cpus = count }
        if let quota = host?.CpuQuota, quota > 0, let period = host?.CpuPeriod, period > 0 {
            cpus = (quota + period - 1) / period
        }
        if let cpus { args += ["-c", "\(cpus)"] }
        if let shares = host?.CpuShares, shares > 0, shares != 1024 {
            warnings.append("CpuShares is ignored: every container gets dedicated CPUs.")
        }
        if let shm = host?.ShmSize, shm > 0 { args += ["--shm-size", "\((shm + (1 << 20) - 1) >> 20)M"] }

        // Security and process.
        // Privileged inside its own VM: every capability. Host devices stay
        // out of reach either way.
        if host?.Privileged == true {
            args += ["--cap-add", "ALL"]
        } else {
            for cap in host?.CapAdd ?? [] { args += ["--cap-add", cap] }
        }
        for cap in host?.CapDrop ?? [] { args += ["--cap-drop", cap] }
        if host?.ReadonlyRootfs == true { args.append("--read-only") }
        for server in host?.Dns ?? [] { args += ["--dns", server] }
        for domain in host?.DnsSearch ?? [] { args += ["--dns-search", domain] }
        for option in host?.DnsOptions ?? [] { args += ["--dns-option", option] }
        for limit in host?.Ulimits ?? [] { args += ["--ulimit", "\(limit.Name)=\(limit.Soft):\(limit.Hard)"] }
        if host?.Init == true { args.append("--init") }
        if host?.AutoRemove == true {
            args.append("--rm")
            labels[DockerLabels.autoRemove] = "true"
        }
        if let opts = host?.SecurityOpt, !opts.isEmpty {
            warnings.append("SecurityOpt is ignored: \(opts.joined(separator: ", ")).")
        }
        if let type = host?.LogConfig?.Type, !type.isEmpty, type != "json-file" {
            warnings.append("Logging driver \"\(type)\" is not available; logs are kept by the runtime.")
        }

        for key in labels.keys.sorted() { args += ["-l", "\(key)=\(LabelValue.encode(labels[key]!))"] }

        // Command: entrypoint's first word goes to --entrypoint, the rest
        // leads the arguments.
        let entrypoint = request.Entrypoint?.values ?? []
        let command = request.Cmd?.values ?? []
        if let first = entrypoint.first {
            args += ["--entrypoint", first]
        }
        args.append(image)
        args += Array(entrypoint.dropFirst()) + command

        return Result(arguments: args, warnings: warnings, anonymousVolumes: anonymous,
                      volumeMounts: volumeMounts, image: image)
    }

    /// Fields with no equivalent in a per-container VM: refused by name.
    static func refuseUnsupported(_ request: CreateRequest) throws {
        let host = request.HostConfig
        func refuse(_ field: String, _ why: String) throws -> Never {
            throw DockerAPIError.badParameter("\(field) is not supported by Irekobox: \(why)")
        }
        if !(host?.Devices ?? []).isEmpty { try refuse("HostConfig.Devices", "host devices can't be passed to the VM") }
        if !(host?.DeviceRequests ?? []).isEmpty { try refuse("HostConfig.DeviceRequests", "GPUs can't be passed to the VM") }
        if !(host?.Sysctls ?? [:]).isEmpty { try refuse("HostConfig.Sysctls", "kernel parameters are fixed per VM") }
        if let pid = host?.PidMode, !pid.isEmpty, pid != "private" { try refuse("HostConfig.PidMode", "PID namespaces can't be shared") }
        if let ipc = host?.IpcMode, !ipc.isEmpty, !["private", "shareable", "none"].contains(ipc) {
            try refuse("HostConfig.IpcMode", "IPC namespaces can't be shared")
        }
        if let userns = host?.UsernsMode, !userns.isEmpty { try refuse("HostConfig.UsernsMode", "user namespaces are not configurable") }
        if !(host?.ExtraHosts ?? []).isEmpty { try refuse("HostConfig.ExtraHosts", "/etc/hosts entries can't be added") }
    }

    /// Where containers look for the Docker API (Testcontainers' Ryuk, log
    /// collectors). The source is often the client's own socket path, so
    /// only the target is matched.
    static let dockerSocketTarget = "/var/run/docker.sock"

    /// The runtime relays a bind-mounted Unix socket into the VM over vsock
    /// (as for `--ssh`); handing it our socket gives the container this API.
    static func dockerSocketMount(_ socket: String?) throws -> [String] {
        guard let socket else {
            throw DockerAPIError.badParameter("mounting \(dockerSocketTarget) needs the Irekobox Docker API socket")
        }
        return ["-v", "\(socket):\(dockerSocketTarget)"]
    }

    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// `src:dst[:ro|rw|z|Z…]` → `src:dst[:ro]`.
    static func bindSpec(_ bind: String) throws -> String {
        let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw DockerAPIError.badParameter("invalid volume specification: '\(bind)'")
        }
        let options = parts.count > 2 ? parts[2].split(separator: ",").map(String.init) : []
        return "\(parts[0]):\(parts[1])" + (options.contains("ro") ? ":ro" : "")
    }

    /// "80/tcp" → (80, "tcp").
    static func containerPort(_ key: String) throws -> (Int, String) {
        let parts = key.split(separator: "/")
        guard let first = parts.first, let port = Int(first), (1...65535).contains(port) else {
            throw DockerAPIError.badParameter("invalid port specification: \"\(key)\"")
        }
        return (port, parts.count > 1 ? parts[1].lowercased() : "tcp")
    }

    /// Stable per container and path, short enough for a volume name.
    static func anonymousVolumeName(container: String, path: String) -> String {
        let hash = path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "\(container)-anon-\(String(hash, radix: 16).prefix(10))"
    }
}

extension JSONEncoder {
    /// Stable output (sorted keys), for values compared as text.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
