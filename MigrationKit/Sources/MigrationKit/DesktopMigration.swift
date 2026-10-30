import Foundation

/// Moving a Docker Desktop setup to Irekobox: what there is, what
/// moves as is, what moves with changes, and what can't move.
public enum DesktopMigration {
    /// Docker Desktop's API socket.
    public static var defaultSourceSocket: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/run/docker.sock").path
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case network, volume, image, container, registry
    }

    public struct Problem: Codable, Hashable, Sendable {
        public enum Level: String, Codable, Sendable {
            /// Moves, but something about it changes.
            case adjusted
            /// Can't move.
            case blocked
        }
        public let level: Level
        public let text: String

        public init(_ level: Level, _ text: String) {
            self.level = level
            self.text = text
        }
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        /// `kind:name`, stable across scans (progress is kept by it).
        public let id: String
        public let kind: Kind
        public let name: String
        public let detail: String
        public let size: Int64?
        public let problems: [Problem]
        /// Items this one needs (a container's image, volumes and networks).
        public let needs: [String]
        /// What the runner sends: volume/network create bodies, container
        /// create body plus whether it was running, image references.
        public let payload: Payload

        public var movable: Bool { kind != .registry && !problems.contains { $0.level == .blocked } }
    }

    public struct Payload: Codable, Hashable, Sendable {
        public var create: JSONValue?
        public var references: [String]?
        public var wasRunning: Bool?
    }

    public struct Inventory: Sendable {
        public let items: [Item]
        public let sourceVersion: String
    }

    // MARK: - Scan

    /// Read Docker Desktop (read-only).
    public static func scan(source: UnixHTTP, dockerConfig: URL? = nil,
                            fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
                            async throws -> Inventory {
        func json(_ path: String) async throws -> Any {
            let response = try await source.get(path)
            guard response.ok else { throw ScanError.api(path, response.message) }
            return try JSONSerialization.jsonObject(with: response.body)
        }
        let version = (try? await json("/version") as? [String: Any])?["Version"] as? String ?? "?"
        let networks = try await json("/networks") as? [[String: Any]] ?? []
        let volumes = (try await json("/volumes") as? [String: Any])?["Volumes"] as? [[String: Any]] ?? []
        let images = try await json("/images/json") as? [[String: Any]] ?? []
        let summaries = try await json("/containers/json?all=1") as? [[String: Any]] ?? []
        var containers: [[String: Any]] = []
        for summary in summaries {
            guard let id = summary["Id"] as? String,
                  let inspect = try? await json("/containers/\(id)/json") as? [String: Any] else { continue }
            containers.append(inspect)
        }
        let df = try? await json("/system/df?verbose=1") as? [String: Any]
        var sizes: [String: Int64] = [:]
        let volumeRows = (df?["Volumes"] as? [[String: Any]])
            ?? ((df?["VolumeUsage"] as? [String: Any])?["Items"] as? [[String: Any]]) ?? []
        for row in volumeRows {
            if let name = row["Name"] as? String, let usage = row["UsageData"] as? [String: Any],
               let size = (usage["Size"] as? NSNumber)?.int64Value, size >= 0 {
                sizes[name] = size
            }
        }
        let registries = dockerConfig.flatMap(registryHosts) ?? []
        let items = plan(networks: networks, volumes: volumes, volumeSizes: sizes, images: images,
                         containers: containers, registries: registries, fileExists: fileExists)
        return Inventory(items: items, sourceVersion: version)
    }

    public enum ScanError: Error, LocalizedError {
        case api(String, String)
        public var errorDescription: String? {
            switch self {
            case .api(let path, let message): return String(localized: "Docker Desktop answered \(path) with: \(message)")
            }
        }
    }

    /// Registries the user signed in to (names only; secrets stay put).
    static func registryHosts(_ config: URL) -> [String] {
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let auths = (object["auths"] as? [String: Any])?.keys.map { $0 } ?? []
        let helpers = (object["credHelpers"] as? [String: Any])?.keys.map { $0 } ?? []
        return Array(Set(auths + helpers)).sorted()
    }

    // MARK: - Plan

    static let builtinNetworks: Set<String> = ["bridge", "host", "none"]

    static func plan(networks: [[String: Any]], volumes: [[String: Any]], volumeSizes: [String: Int64],
                     images: [[String: Any]], containers: [[String: Any]], registries: [String],
                     fileExists: (String) -> Bool) -> [Item] {
        var items: [Item] = []

        for network in networks {
            guard let name = network["Name"] as? String, !builtinNetworks.contains(name),
                  (network["Driver"] as? String ?? "bridge") == "bridge" || network["Driver"] == nil else { continue }
            var problems: [Problem] = []
            var body: [String: Any] = ["Name": name, "Labels": network["Labels"] as? [String: String] ?? [:]]
            if network["Internal"] as? Bool == true { body["Internal"] = true }
            let configs = (network["IPAM"] as? [String: Any])?["Config"] as? [[String: Any]] ?? []
            if !configs.isEmpty {
                let subnets = configs.compactMap { $0["Subnet"] as? String }.joined(separator: ", ")
                problems.append(Problem(.adjusted, String(localized: "Gets a new subnet (Docker's \(subnets) isn't kept)")))
            }
            items.append(Item(id: "network:\(name)", kind: .network, name: name, detail: String(localized: "bridge network", comment: "Kind of item found in Docker Desktop, shown under its name"),
                              size: nil, problems: problems, needs: [],
                              payload: Payload(create: JSONValue(body))))
        }
        for network in networks {
            guard let name = network["Name"] as? String, !builtinNetworks.contains(name),
                  let driver = network["Driver"] as? String, driver != "bridge" else { continue }
            items.append(Item(id: "network:\(name)", kind: .network, name: name, detail: String(localized: "\(driver) network", comment: "Kind of item found in Docker Desktop, shown under its name"), size: nil,
                              problems: [Problem(.blocked, String(localized: "Only bridge networks exist (this one uses \(driver))"))],
                              needs: [], payload: Payload()))
        }

        // Containers per volume: a volume is a disk image here, which one
        // running VM at a time can use.
        var users: [String: [String]] = [:]
        for inspect in containers {
            let container = (inspect["Name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for mount in inspect["Mounts"] as? [[String: Any]] ?? [] where mount["Type"] as? String == "volume" {
                if let name = mount["Name"] as? String { users[name, default: []].append(container) }
            }
        }
        for volume in volumes {
            guard let name = volume["Name"] as? String else { continue }
            let driver = volume["Driver"] as? String ?? "local"
            var problems: [Problem] = []
            if let sharing = users[name], sharing.count > 1 {
                let names = sharing.sorted().joined(separator: ", ")
                problems.append(Problem(.adjusted, String(localized: "Shared by \(names); here only one running container at a time can use a volume")))
            }
            let options = volume["Options"] as? [String: String] ?? [:]
            if driver != "local" {
                problems.append(Problem(.blocked, String(localized: "Volume driver \(driver) isn't available")))
            } else if !options.isEmpty {
                let keys = options.keys.sorted().joined(separator: ", ")
                problems.append(Problem(.blocked, String(localized: "A local volume with mount options (\(keys)), e.g. NFS or a bound folder")))
            }
            let body: [String: Any] = ["Name": name, "Labels": volume["Labels"] as? [String: String] ?? [:]]
            items.append(Item(id: "volume:\(name)", kind: .volume, name: name,
                              detail: isAnonymous(name) ? String(localized: "anonymous volume", comment: "Kind of item found in Docker Desktop, shown under its name") : String(localized: "volume", comment: "Kind of item found in Docker Desktop, shown under its name"),
                              size: volumeSizes[name], problems: problems, needs: [],
                              payload: Payload(create: JSONValue(body))))
        }

        // Images: one item per image, all its tags; untagged ones are skipped.
        var imageIDs: [String: String] = [:]          // tag → item id
        for image in images {
            guard let id = image["Id"] as? String else { continue }
            let tags = (image["RepoTags"] as? [String] ?? []).filter { $0 != "<none>:<none>" }
            guard !tags.isEmpty else { continue }
            let itemID = "image:\(id)"
            for tag in tags { imageIDs[tag] = itemID }
            let size = (image["Size"] as? NSNumber)?.int64Value
            items.append(Item(id: itemID, kind: .image, name: tags.sorted()[0],
                              detail: tags.count > 1 ? String(localized: "\(tags.count) tags") : String(localized: "image", comment: "Kind of item found in Docker Desktop, shown under its name"),
                              size: size, problems: [], needs: [],
                              payload: Payload(references: tags.sorted())))
        }

        for inspect in containers {
            items.append(containerItem(inspect, imageItems: imageIDs, fileExists: fileExists))
        }

        for host in registries {
            items.append(Item(id: "registry:\(host)", kind: .registry, name: host, detail: String(localized: "registry sign-in", comment: "Kind of item found in Docker Desktop, shown under its name"), size: nil,
                              problems: [Problem(.adjusted, String(localized: "Sign in again in Settings › Registries; passwords aren't copied"))],
                              needs: [], payload: Payload()))
        }
        return items
    }

    static func isAnonymous(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy(\.isHexDigit)
    }

    static func isDockerSocket(_ path: String) -> Bool {
        path.hasSuffix("/docker.sock") || path == "/var/run/docker.sock" || path == "/run/docker.sock"
    }

    /// Docker's inspect → a create body for Irekobox, with what had
    /// to change and what can't move.
    static func containerItem(_ inspect: [String: Any], imageItems: [String: String],
                              fileExists: (String) -> Bool) -> Item {
        let name = (inspect["Name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = inspect["Config"] as? [String: Any] ?? [:]
        let host = inspect["HostConfig"] as? [String: Any] ?? [:]
        let state = inspect["State"] as? [String: Any] ?? [:]
        let image = config["Image"] as? String ?? ""
        var problems: [Problem] = []
        var needs: [String] = []

        var body: [String: Any] = [:]
        for key in ["Hostname", "Domainname", "User", "Env", "Cmd", "Entrypoint", "Image", "WorkingDir", "Labels",
                    "ExposedPorts", "Tty", "OpenStdin", "StdinOnce", "AttachStdin", "AttachStdout", "AttachStderr",
                    "StopSignal", "StopTimeout", "Healthcheck"] {
            if let value = config[key], !(value is NSNull) { body[key] = value }
        }
        // Docker's default hostname is the container's short ID: drop it.
        if let hostname = body["Hostname"] as? String, let id = inspect["Id"] as? String, id.hasPrefix(hostname) {
            body["Hostname"] = nil
        }

        var hostConfig: [String: Any] = [:]
        for key in ["PortBindings", "RestartPolicy", "AutoRemove", "CapAdd", "CapDrop", "Memory", "NanoCpus",
                    "CpuCount", "CpuQuota", "CpuPeriod", "Privileged", "ReadonlyRootfs", "Tmpfs", "Ulimits", "Init",
                    "Dns", "DnsSearch", "DnsOptions", "ShmSize"] {
            if let value = host[key], !(value is NSNull) { hostConfig[key] = value }
        }
        if (hostConfig["Memory"] as? NSNumber)?.int64Value == 0 { hostConfig["Memory"] = nil }
        if (hostConfig["NanoCpus"] as? NSNumber)?.int64Value == 0 { hostConfig["NanoCpus"] = nil }

        // Mounts are the truth (they include image VOLUMEs): bind or named.
        var binds: [String] = []
        for mount in inspect["Mounts"] as? [[String: Any]] ?? [] {
            let destination = mount["Destination"] as? String ?? ""
            let readOnly = (mount["RW"] as? Bool) == false
            switch mount["Type"] as? String {
            case "volume":
                guard let volume = mount["Name"] as? String else { continue }
                binds.append("\(volume):\(destination)\(readOnly ? ":ro" : "")")
                needs.append("volume:\(volume)")
            case "bind":
                let source = mount["Source"] as? String ?? ""
                if isDockerSocket(source) {
                    problems.append(Problem(.adjusted, String(localized: "The Docker socket mount (\(source)) is left out: a container can't receive a socket")))
                    continue
                }
                if !fileExists(source) {
                    problems.append(Problem(.blocked, String(localized: "Mounts \(source), which doesn't exist on this Mac")))
                    continue
                }
                binds.append("\(source):\(destination)\(readOnly ? ":ro" : "")")
            default:
                continue    // tmpfs comes from HostConfig.Tmpfs
            }
        }
        if !binds.isEmpty { hostConfig["Binds"] = binds }

        if !(host["ExtraHosts"] as? [String] ?? []).isEmpty {
            let entries = (host["ExtraHosts"] as? [String] ?? []).joined(separator: ", ")
            problems.append(Problem(.adjusted, String(localized: "Extra /etc/hosts entries (\(entries)) are left out")))
        }
        if !(host["Sysctls"] as? [String: String] ?? [:]).isEmpty {
            problems.append(Problem(.adjusted, String(localized: "Kernel parameters (sysctls) are left out")))
        }
        if !(host["Devices"] as? [Any] ?? []).isEmpty {
            problems.append(Problem(.blocked, String(localized: "Uses host devices")))
        }
        if !(host["DeviceRequests"] as? [Any] ?? []).isEmpty {
            problems.append(Problem(.blocked, String(localized: "Uses GPUs")))
        }
        if let mode = host["PidMode"] as? String, mode == "host" || mode.hasPrefix("container:") {
            problems.append(Problem(.adjusted, String(localized: "Shares the \(mode) PID namespace; it gets its own")))
        }
        if let mode = host["IpcMode"] as? String, mode == "host" || mode.hasPrefix("container:") {
            problems.append(Problem(.adjusted, String(localized: "Shares the \(mode) IPC namespace; it gets its own")))
        }

        let mode = host["NetworkMode"] as? String ?? "default"
        var endpoints: [String: Any] = [:]
        let attached = (inspect["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any] ?? [:]
        if mode == "host" {
            problems.append(Problem(.blocked, String(localized: "Uses the host network; each container has its own VM network")))
        } else if mode.hasPrefix("container:") {
            problems.append(Problem(.blocked, String(localized: "Shares another container's network")))
        } else if mode == "none" {
            hostConfig["NetworkMode"] = "none"
        } else {
            let shortID = String((inspect["Id"] as? String ?? "").prefix(12))
            for (network, settings) in attached.sorted(by: { $0.key < $1.key }) {
                let aliases = ((settings as? [String: Any])?["Aliases"] as? [String] ?? [])
                    .filter { $0 != shortID && $0 != name }
                endpoints[network] = aliases.isEmpty ? [String: Any]() : ["Aliases": aliases]
                if !builtinNetworks.contains(network) { needs.append("network:\(network)") }
            }
            if mode != "default", mode != "bridge" { hostConfig["NetworkMode"] = mode }
        }

        if let imageItem = imageItems[image] ?? imageItems[image.contains(":") ? image : image + ":latest"] {
            needs.append(imageItem)
        } else if !image.contains("@") {
            problems.append(Problem(.adjusted, String(localized: "Its image \(image) isn't tagged locally; it will be pulled")))
        }

        body["HostConfig"] = hostConfig
        if !endpoints.isEmpty { body["NetworkingConfig"] = ["EndpointsConfig": endpoints] }

        let running = state["Running"] as? Bool ?? false
        let project = (config["Labels"] as? [String: String])?["com.docker.compose.project"]
        let status = running ? String(localized: "running", comment: "Container state") : String(localized: "stopped", comment: "Container state")
        let detail = [project.map { String(localized: "compose project \($0)") }, status, image]
            .compactMap { $0 }.joined(separator: " · ")
        return Item(id: "container:\(name)", kind: .container, name: name, detail: detail, size: nil,
                    problems: problems, needs: Array(Set(needs)).sorted(),
                    payload: Payload(create: JSONValue(body), wasRunning: running))
    }
}

/// Any JSON value, kept Codable so a plan can be saved and resumed.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ any: Any) {
        switch any {
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as Bool: self = .bool(value)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    /// Back to Foundation types for JSONSerialization.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value.rounded() == value && abs(value) < 9e15 ? Int64(value) as Any : value
        case .string(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
