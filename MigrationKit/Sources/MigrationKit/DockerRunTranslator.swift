import Foundation

/// Translates a `docker run …` command line into a `container run …` argv,
/// mapping flags and reporting partial/unsupported ones. Pure and testable.
public struct DockerRunTranslator: Sendable {
    public init() {}

    public func translate(_ command: String) throws -> DockerRunTranslation {
        let tokens = Self.tokenize(command)
        let body = Self.stripProgramPrefix(tokens)
        let parsed = Self.parse(body)

        guard let image = parsed.image else { throw DockerRunError.noImage }

        var arguments = ["run"]
        var warnings: [MigrationWarning] = []
        for flag in parsed.flags {
            let (args, warning) = Self.map(flag)
            arguments += args
            if let warning { warnings.append(warning) }
        }
        arguments.append(image)
        arguments += parsed.command

        return DockerRunTranslation(arguments: arguments, image: image, warnings: warnings)
    }

    // MARK: - Tokenizer (shell-like: quotes, escapes, line continuations)

    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var escaped = false

        for ch in input {
            if escaped {
                if ch != "\n" { current.append(ch); hasToken = true }
                escaped = false
                continue
            }
            if ch == "\\" && !inSingle { escaped = true; hasToken = true; continue }
            if ch == "'" && !inDouble { inSingle.toggle(); hasToken = true; continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); hasToken = true; continue }
            if (ch == " " || ch == "\t" || ch == "\n") && !inSingle && !inDouble {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Drop leading `sudo` / `docker` / `podman` / `container` and a `run` verb.
    static func stripProgramPrefix(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while let first = tokens.first, ["sudo", "docker", "podman", "container"].contains(first) {
            tokens.removeFirst()
        }
        if tokens.first == "run" { tokens.removeFirst() }
        return tokens
    }

    // MARK: - Flag parsing (pflag-like)

    struct Flag: Hashable { let name: String; let value: String? }
    struct Parsed { var flags: [Flag]; var image: String?; var command: [String] }

    private static let shortMap: [Character: String] = [
        "d": "detach", "i": "interactive", "t": "tty", "e": "env", "p": "publish",
        "v": "volume", "u": "user", "w": "workdir", "m": "memory", "l": "label",
        "h": "hostname", "c": "cpu-shares", "a": "attach",
    ]

    private static let valueFlags: Set<String> = [
        "name", "env", "env-file", "publish", "expose", "volume", "mount", "workdir",
        "user", "memory", "cpus", "cpu-shares", "cpuset-cpus", "cap-add", "cap-drop",
        "dns", "dns-search", "dns-option", "label", "platform", "entrypoint",
        "network", "net", "hostname", "restart", "add-host", "ulimit", "shm-size",
        "runtime", "device", "gpus", "sysctl", "security-opt", "ipc", "pid", "uts",
        "userns", "attach", "log-driver", "log-opt", "pull", "stop-signal",
    ]

    static func parse(_ tokens: [String]) -> Parsed {
        var result = Parsed(flags: [], image: nil, command: [])
        var idx = 0
        while idx < tokens.count {
            let token = tokens[idx]

            if result.image == nil, token.hasPrefix("--") {
                let bodyText = String(token.dropFirst(2))
                if let eq = bodyText.firstIndex(of: "=") {
                    result.flags.append(Flag(name: String(bodyText[..<eq]),
                                             value: String(bodyText[bodyText.index(after: eq)...])))
                } else if valueFlags.contains(bodyText), idx + 1 < tokens.count {
                    result.flags.append(Flag(name: bodyText, value: tokens[idx + 1])); idx += 1
                } else {
                    result.flags.append(Flag(name: bodyText, value: nil))
                }
            } else if result.image == nil, token.hasPrefix("-"), token.count > 1 {
                let chars = Array(token.dropFirst())
                var j = 0
                while j < chars.count {
                    let c = chars[j]
                    guard let long = shortMap[c] else {
                        result.flags.append(Flag(name: "-\(c)", value: nil)); j += 1; continue
                    }
                    if valueFlags.contains(long) {
                        let rest = String(chars[(j + 1)...])
                        if !rest.isEmpty {
                            result.flags.append(Flag(name: long, value: rest))
                        } else if idx + 1 < tokens.count {
                            result.flags.append(Flag(name: long, value: tokens[idx + 1])); idx += 1
                        } else {
                            result.flags.append(Flag(name: long, value: nil))
                        }
                        break
                    } else {
                        result.flags.append(Flag(name: long, value: nil)); j += 1
                    }
                }
            } else if result.image == nil {
                result.image = token
            } else {
                result.command.append(token)
            }
            idx += 1
        }
        return result
    }

    // MARK: - Flag mapping

    private static let directValue: [String: String] = [
        "name": "--name", "env": "--env", "env-file": "--env-file", "publish": "--publish",
        "volume": "--volume", "mount": "--mount", "workdir": "--workdir", "user": "--user",
        "memory": "--memory", "cpus": "--cpus", "cap-add": "--cap-add", "cap-drop": "--cap-drop",
        "dns": "--dns", "dns-search": "--dns-search", "dns-option": "--dns-option",
        "label": "--label", "platform": "--platform", "entrypoint": "--entrypoint",
        "network": "--network", "net": "--network", "ulimit": "--ulimit",
        "shm-size": "--shm-size", "runtime": "--runtime",
    ]
    private static let directBool: [String: String] = [
        "detach": "--detach", "read-only": "--read-only", "init": "--init",
        "tty": "--tty", "interactive": "--interactive", "rm": "--rm",
    ]
    private static let unsupported: Set<String> = [
        "privileged", "cpu-shares", "cpuset-cpus", "add-host", "gpus", "device",
        "ipc", "pid", "uts", "userns", "security-opt",
    ]
    private static let partial: [String: String] = [
        "hostname": String(localized: "no `--hostname`; `container` defaults to the container name"),
        "expose": String(localized: "informational; intra-network reachability is implicit"),
        "sysctl": String(localized: "no `run` flag in `container`"),
    ]
    private static let infoFlags: [String: String] = [
        "restart": String(localized: "not a `container run` flag; Irekobox can enforce the policy"),
        "attach": String(localized: "ignored; use logs/exec"),
        "pull": String(localized: "ignored", comment: "Note on a docker run flag that was left out of the translated command"),
        "log-driver": String(localized: "ignored", comment: "Note on a docker run flag that was left out of the translated command"),
        "log-opt": String(localized: "ignored", comment: "Note on a docker run flag that was left out of the translated command"),
    ]

    static func map(_ flag: Flag) -> ([String], MigrationWarning?) {
        let name = flag.name
        if let mapped = directBool[name] { return ([mapped], nil) }
        if let mapped = directValue[name] {
            guard let value = flag.value else {
                return ([], MigrationWarning(flag: name, message: String(localized: "missing value; dropped"), severity: .unsupported))
            }
            return ([mapped, value], nil)
        }
        if unsupported.contains(name) {
            return ([], MigrationWarning(flag: name,
                message: String(localized: "no analog in `container`'s per-VM model; dropped"), severity: .unsupported))
        }
        if let message = partial[name] {
            return ([], MigrationWarning(flag: name, message: message, severity: .partial))
        }
        if let message = infoFlags[name] {
            return ([], MigrationWarning(flag: name, message: message, severity: .info))
        }
        return ([], MigrationWarning(flag: name, message: String(localized: "unrecognized flag; dropped"), severity: .unsupported))
    }
}
