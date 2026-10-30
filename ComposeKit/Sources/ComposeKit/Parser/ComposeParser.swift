import Foundation
import Yams

/// Result of parsing: the typed model plus the raw key set per service
/// (used by ``ComposePlanner`` to warn about partial/unsupported fields).
public struct ParsedCompose: Sendable {
    public let file: ComposeFile
    /// service name → set of keys present in the source YAML.
    public let rawServiceKeys: [String: Set<String>]
}

public enum ComposeParseError: Error, LocalizedError {
    case invalidYAML(String)
    case noServices

    public var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail): return String(localized: "Invalid compose YAML: \(detail)")
        case .noServices: return String(localized: "Compose file has no `services`.")
        }
    }
}

/// Parses Compose YAML into a typed ``ComposeFile``.
public struct ComposeParser: Sendable {
    /// Environment used for `${VAR}` interpolation. Defaults to the process env.
    public let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func parse(_ yaml: String) throws -> ParsedCompose {
        let interpolated = Self.interpolate(yaml, environment: environment)

        let file: ComposeFile
        do {
            file = try YAMLDecoder().decode(ComposeFile.self, from: interpolated)
        } catch {
            throw ComposeParseError.invalidYAML(String(describing: error))
        }
        guard !file.services.isEmpty else { throw ComposeParseError.noServices }

        return ParsedCompose(file: file, rawServiceKeys: Self.rawServiceKeys(interpolated))
    }

    public func parse(contentsOf url: URL) throws -> ParsedCompose {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Raw service keys (for warnings)

    static func rawServiceKeys(_ yaml: String) -> [String: Set<String>] {
        guard let node = try? Yams.compose(yaml: yaml),
              let services = node.mapping?["services"]?.mapping else {
            return [:]
        }
        var result: [String: Set<String>] = [:]
        for (nameNode, serviceNode) in services {
            guard let name = nameNode.string, let mapping = serviceNode.mapping else { continue }
            result[name] = Set(mapping.keys.compactMap { $0.string })
        }
        return result
    }

    // MARK: - Variable interpolation

    /// Replace `${VAR}`, `${VAR:-default}`, `${VAR-default}`, and `$VAR`.
    /// Unset variables without a default become empty strings.
    static func interpolate(_ input: String, environment: [String: String]) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var index = input.startIndex

        while index < input.endIndex {
            let ch = input[index]
            guard ch == "$" else { output.append(ch); index = input.index(after: index); continue }

            let next = input.index(after: index)
            if next < input.endIndex, input[next] == "$" {
                output.append("$") // escaped $$
                index = input.index(after: next)
                continue
            }
            if next < input.endIndex, input[next] == "{" {
                // ${ ... }
                guard let close = input[next...].firstIndex(of: "}") else {
                    output.append(ch); index = input.index(after: index); continue
                }
                let expr = String(input[input.index(after: next)..<close])
                output.append(resolve(expr, environment: environment))
                index = input.index(after: close)
            } else if next < input.endIndex, input[next].isLetter || input[next] == "_" {
                // $VAR
                var end = next
                while end < input.endIndex, input[end].isLetter || input[end].isNumber || input[end] == "_" {
                    end = input.index(after: end)
                }
                let name = String(input[next..<end])
                output.append(environment[name] ?? "")
                index = end
            } else {
                output.append(ch)
                index = input.index(after: index)
            }
        }
        return output
    }

    private static func resolve(_ expr: String, environment: [String: String]) -> String {
        if let range = expr.range(of: ":-") {
            let name = String(expr[..<range.lowerBound])
            let fallback = String(expr[range.upperBound...])
            let value = environment[name]
            return (value?.isEmpty == false ? value : nil) ?? fallback
        }
        if let range = expr.range(of: "-") {
            let name = String(expr[..<range.lowerBound])
            let fallback = String(expr[range.upperBound...])
            return environment[name] ?? fallback
        }
        return environment[expr] ?? ""
    }
}
