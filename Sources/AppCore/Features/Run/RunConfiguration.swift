import Foundation
import ComposeKit

/// Everything the Run sheet collects, turned into `container run` arguments
/// and checked before anything is started.
struct RunConfiguration: Equatable {
    enum PortProtocol: String, CaseIterable, Identifiable {
        case tcp = "TCP", udp = "UDP"
        var id: String { rawValue }
    }

    struct Port: Identifiable, Equatable {
        let id = UUID()
        var host = ""
        var container = ""
        var proto: PortProtocol = .tcp
    }

    struct Mount: Identifiable, Equatable {
        let id = UUID()
        /// A host folder (absolute or `~/…`) or a named volume.
        var source = ""
        var target = ""
        var readOnly = false

        var isNamedVolume: Bool { !source.isEmpty && !source.contains("/") && !source.hasPrefix("~") }
    }

    struct Variable: Identifiable, Equatable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    var image = ""
    var name = ""
    var ports: [Port] = []
    var mounts: [Mount] = []
    var variables: [Variable] = []
    /// `nil` = the image/engine default.
    var cpus: Int?
    var memoryMiB: Int?
    /// Run the linux/amd64 variant (emulated with Rosetta).
    var amd64 = false
    /// `nil` = the default network.
    var network: String?
    var removeWhenStopped = false
    /// Optional command, shell syntax (quotes allowed).
    var command = ""

    // MARK: - Arguments

    /// Arguments after `container run`.
    func arguments(homeDirectory: String = NSHomeDirectory()) -> [String] {
        var args = ["--detach"]
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { args += ["--name", name] }
        for port in ports where !port.host.isEmpty && !port.container.isEmpty {
            args += ["--publish", "\(port.host):\(port.container)" + (port.proto == .udp ? "/udp" : "")]
        }
        for mount in mounts where !mount.source.isEmpty && !mount.target.isEmpty {
            let source = mount.source.hasPrefix("~")
                ? homeDirectory + mount.source.dropFirst()
                : mount.source
            args += ["--volume", "\(source):\(mount.target)" + (mount.readOnly ? ":ro" : "")]
        }
        for variable in variables where !variable.key.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--env", "\(variable.key.trimmingCharacters(in: .whitespaces))=\(variable.value)"]
        }
        if let cpus { args += ["--cpus", "\(cpus)"] }
        if let memoryMiB { args += ["--memory", "\(memoryMiB)M"] }
        if amd64 { args += ["--platform", "linux/amd64"] }
        if let network, !network.isEmpty { args += ["--network", network] }
        if removeWhenStopped { args.append("--rm") }
        args.append(image.trimmingCharacters(in: .whitespaces))
        args += ShellTokenizer.split(command)
        return args
    }

    /// The full command, for the preview and for copying.
    func commandLine() -> String {
        (["container", "run"] + arguments(homeDirectory: "~").map(ContainerList.shellQuoted))
            .joined(separator: " ")
    }

    // MARK: - Checks

    struct Issue: Equatable, Identifiable {
        enum Severity { case error, warning }
        enum Field: Hashable { case image, name, port(UUID), mount(UUID), variable(UUID) }

        let field: Field
        let severity: Severity
        let message: String
        /// A one-click fix, e.g. a free host port.
        var suggestion: Suggestion?

        var id: String { "\(field)-\(message)" }
    }

    enum Suggestion: Equatable {
        case hostPort(portID: UUID, value: String)
    }

    /// Host ports macOS itself listens on (AirPlay Receiver).
    static let macOSReservedPorts: [Int: String] = [5000: "AirPlay Receiver", 7000: "AirPlay Receiver"]

    /// Problems that block running (errors) or deserve attention (warnings).
    func issues(existingNames: Set<String>, usedHostPorts: Set<Int>) -> [Issue] {
        var issues: [Issue] = []
        if image.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(Issue(field: .image, severity: .error, message: String(localized: "Choose an image to run.")))
        } else if image.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
            issues.append(Issue(field: .image, severity: .error, message: String(localized: "Choose a tag, or remove the “:”.")))
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty {
            if trimmedName.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) == nil {
                issues.append(Issue(field: .name, severity: .error,
                                    message: String(localized: "Use letters, digits, “.”, “_” or “-”, starting with a letter or digit.")))
            } else if existingNames.contains(trimmedName) {
                issues.append(Issue(field: .name, severity: .error,
                                    message: String(localized: "A container named “\(trimmedName)” already exists.")))
            }
        }

        var seenHostPorts: [String: UUID] = [:]
        for port in ports where !(port.host.isEmpty && port.container.isEmpty) {
            guard let host = Int(port.host), (1...65535).contains(host) else {
                issues.append(Issue(field: .port(port.id), severity: .error, message: String(localized: "Host port must be 1–65535.")))
                continue
            }
            guard let containerPort = Int(port.container), (1...65535).contains(containerPort) else {
                issues.append(Issue(field: .port(port.id), severity: .error, message: String(localized: "Container port must be 1–65535.")))
                continue
            }
            let key = "\(host)/\(port.proto.rawValue)"
            if seenHostPorts[key] != nil {
                issues.append(Issue(field: .port(port.id), severity: .error,
                                    message: String(localized: "Host port \(String(host)) is published twice.")))
            }
            seenHostPorts[key] = port.id
            let free = freePort(near: host, used: usedHostPorts.union(Set(ports.compactMap { Int($0.host) })))
            if usedHostPorts.contains(host) {
                issues.append(Issue(field: .port(port.id), severity: .error,
                                    message: String(localized: "Host port \(String(host)) is already published by another container."),
                                    suggestion: .hostPort(portID: port.id, value: "\(free)")))
            } else if let owner = Self.macOSReservedPorts[host] {
                issues.append(Issue(field: .port(port.id), severity: .warning,
                                    message: String(localized: "Port \(String(host)) is used by \(owner) on this Mac."),
                                    suggestion: .hostPort(portID: port.id, value: "\(free)")))
            }
        }

        for mount in mounts where !(mount.source.isEmpty && mount.target.isEmpty) {
            if mount.source.isEmpty || mount.target.isEmpty {
                issues.append(Issue(field: .mount(mount.id), severity: .error,
                                    message: String(localized: "Give both a source and a path in the container.")))
            } else if !mount.target.hasPrefix("/") {
                issues.append(Issue(field: .mount(mount.id), severity: .error,
                                    message: String(localized: "The path in the container must start with “/”.")))
            } else if !mount.isNamedVolume && !mount.source.hasPrefix("/") && !mount.source.hasPrefix("~") {
                issues.append(Issue(field: .mount(mount.id), severity: .error,
                                    message: String(localized: "Use an absolute folder path, ~/…, or a volume name.")))
            }
        }

        for variable in variables where !variable.key.isEmpty || !variable.value.isEmpty {
            if variable.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                issues.append(Issue(field: .variable(variable.id), severity: .error,
                                    message: String(localized: "Variable names use letters, digits and “_”, not starting with a digit.")))
            }
        }
        return issues
    }

    var hasPorts: Bool { ports.contains { !$0.host.isEmpty || !$0.container.isEmpty } }

    /// A nearby free host port: +50 first (5000 → 5050), then upwards.
    private func freePort(near port: Int, used: Set<Int>) -> Int {
        var candidate = port + 50
        while used.contains(candidate) || Self.macOSReservedPorts[candidate] != nil || candidate > 65535 {
            candidate = candidate > 65535 ? 1024 : candidate + 1
        }
        return candidate
    }

    // MARK: - .env files

    /// `KEY=value` lines; blank lines and `#` comments skipped, surrounding
    /// quotes removed, `export ` prefixes allowed.
    static func parseEnvFile(_ text: String) -> [Variable] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return Variable(key: key, value: value)
        }
    }
}
