import Foundation

/// What a planned `container run` argv mounts and runs: read back from the
/// arguments, since the plan carries nothing else (the app rewrites steps and
/// keeps only the argv).
struct RunArguments: Equatable {
    struct NamedVolume: Equatable {
        let name: String
        let target: String
    }

    struct AnonymousVolume: Equatable {
        /// Index of the `--mount` value in the arguments.
        let valueIndex: Int
        let target: String
        let readOnly: Bool
    }

    let image: String
    let namedVolumes: [NamedVolume]
    let anonymousVolumes: [AnonymousVolume]

    /// `run` options that take no value; every other option consumes the next
    /// argument unless written `--option=value`. The planner emits only these.
    static let flags: Set<String> = ["--detach", "-d", "--rm", "--read-only", "--init",
                                     "--tty", "-t", "--interactive", "-i"]

    /// `nil` unless `arguments` is a `run` with an image.
    init?(_ arguments: [String]) {
        guard arguments.first == "run" else { return nil }
        var image: String?
        var named: [NamedVolume] = []
        var anonymous: [AnonymousVolume] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-") else {
                image = argument
                break
            }
            if Self.flags.contains(argument) || argument.contains("=") {
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch argument {
            case "--volume", "-v":
                if let volume = Self.namedVolume(value) { named.append(volume) }
            case "--mount":
                if let (target, readOnly) = Self.anonymousMount(value) {
                    anonymous.append(AnonymousVolume(valueIndex: index + 1, target: target, readOnly: readOnly))
                }
            default:
                break
            }
            index += 2
        }
        guard let image else { return nil }
        self.image = image
        self.namedVolumes = named
        self.anonymousVolumes = anonymous
    }

    /// `name:/target[:ro]` with a volume name, not a host path, as source.
    static func namedVolume(_ value: String) -> NamedVolume? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty, !isPath(parts[0]) else { return nil }
        return NamedVolume(name: parts[0], target: parts[1])
    }

    /// `type=volume,target=/path[,readonly]` without a source.
    static func anonymousMount(_ value: String) -> (target: String, readOnly: Bool)? {
        var type: String?, source: String?, target: String?, readOnly = false
        for field in value.split(separator: ",") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            switch pair[0] {
            case "type": type = pair.last
            case "source", "src": source = pair.last
            case "target", "destination", "dst": target = pair.last
            case "readonly", "ro": readOnly = true
            default: break
            }
        }
        guard type == "volume", source == nil, let target, !target.isEmpty else { return nil }
        return (target, readOnly)
    }

    private static func isPath(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    }
}
