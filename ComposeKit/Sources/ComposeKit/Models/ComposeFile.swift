import Foundation

/// A parsed Compose file (the subset Irekobox maps onto `container`).
public struct ComposeFile: Codable, Sendable {
    public let name: String?
    public let services: [String: Service]
    public let networks: [String: ResourceDef?]?
    public let volumes: [String: ResourceDef?]?
}

/// A top-level `networks:` / `volumes:` entry (value may be `null` → defaults).
public struct ResourceDef: Codable, Sendable {
    public let external: Bool?
    public let name: String?
    public let driver: String?

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self.external = nil; self.name = nil; self.driver = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.external = try c.decodeIfPresent(Bool.self, forKey: .external)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.driver = try c.decodeIfPresent(String.self, forKey: .driver)
    }
}

/// A Compose service. Only fields the planner needs are typed; everything else
/// is observed via raw keys (see ``ComposeParser``) for warnings.
public struct Service: Codable, Sendable {
    public let image: String?
    public let build: BuildSpec?
    public let command: StringOrList?
    public let entrypoint: StringOrList?
    public let environment: KeyValueMap?
    public let envFile: StringOrList?
    public let workingDir: String?
    public let user: String?
    public let ports: [PortMapping]?
    public let volumes: [VolumeMount]?
    public let networks: ServiceNetworks?
    public let dependsOn: DependsOn?
    public let labels: KeyValueMap?
    public let restart: String?
    public let cpus: ScalarValue?
    public let memLimit: String?
    public let readOnly: Bool?
    public let useInit: Bool?
    public let tty: Bool?
    public let stdinOpen: Bool?
    public let capAdd: [String]?
    public let capDrop: [String]?
    public let dns: StringOrList?
    public let containerName: String?
    public let platform: String?
    public let shmSize: String?
    public let profiles: [String]?
    public let scale: Int?
    public let healthcheck: Healthcheck?

    enum CodingKeys: String, CodingKey {
        case image, build, command, entrypoint, environment
        case envFile = "env_file"
        case workingDir = "working_dir"
        case user, ports, volumes, networks
        case dependsOn = "depends_on"
        case labels, restart, cpus
        case memLimit = "mem_limit"
        case readOnly = "read_only"
        case useInit = "init"
        case tty
        case stdinOpen = "stdin_open"
        case capAdd = "cap_add"
        case capDrop = "cap_drop"
        case dns
        case containerName = "container_name"
        case platform
        case shmSize = "shm_size"
        case profiles, scale, healthcheck
    }
}

/// `healthcheck:` — run by the background agent (Docker's rules).
public struct Healthcheck: Codable, Sendable {
    public let test: StringOrList?
    public let interval: String?
    public let timeout: String?
    public let retries: Int?
    public let startPeriod: String?
    public let startInterval: String?
    public let disable: Bool?

    enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries, disable
        case startPeriod = "start_period"
        case startInterval = "start_interval"
    }

    /// Docker's HealthConfig as the agent reads it (durations in ns), or nil
    /// when disabled or without a test. A string test runs in a shell.
    public var dockerJSON: String? {
        if disable == true { return nil }
        let command: [String]
        switch test {
        case .string(let line)?: command = ["CMD-SHELL", line]
        case .list(let list)? where !list.isEmpty:
            command = ["CMD", "CMD-SHELL", "NONE"].contains(list[0]) ? list : ["CMD"] + list
        default: return nil
        }
        if command.first == "NONE" { return nil }
        var object: [String: Any] = ["Test": command]
        for (key, text) in [("Interval", interval), ("Timeout", timeout), ("StartPeriod", startPeriod),
                            ("StartInterval", startInterval)] {
            if let nanos = text.flatMap(Self.nanoseconds) { object[key] = nanos }
        }
        if let retries { object["Retries"] = retries }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Compose durations: `1m30s`, `500ms`, `10s`, `2h`, `1.5s`.
    static func nanoseconds(_ text: String) -> Int64? {
        var total: Double = 0
        var number = ""
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        while let character = rest.first {
            if character.isNumber || character == "." { number.append(character); rest = rest.dropFirst(); continue }
            guard let value = Double(number) else { return nil }
            let unit: Double
            if rest.hasPrefix("ms") { unit = 1e6; rest = rest.dropFirst(2) }
            else if rest.hasPrefix("us") { unit = 1e3; rest = rest.dropFirst(2) }
            else if character == "h" { unit = 3600e9; rest = rest.dropFirst() }
            else if character == "m" { unit = 60e9; rest = rest.dropFirst() }
            else if character == "s" { unit = 1e9; rest = rest.dropFirst() }
            else { return nil }
            total += value * unit
            number = ""
        }
        guard number.isEmpty else { return nil }
        return Int64(total)
    }
}

/// `build:` — string (context path) or object with context/dockerfile/args.
public struct BuildSpec: Codable, Sendable {
    public let context: String?
    public let dockerfile: String?
    public let args: KeyValueMap?

    enum CodingKeys: String, CodingKey { case context, dockerfile, args }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let path = try? single.decode(String.self) {
            self.context = path; self.dockerfile = nil; self.args = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
        self.dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile)
        self.args = try c.decodeIfPresent(KeyValueMap.self, forKey: .args)
    }
}
