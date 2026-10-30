import Foundation

/// A YAML scalar normalized to an optional String (covers string/int/double/bool/null).
public enum ScalarValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return nil
        }
    }
}

/// `string` or `[string]` (e.g. `command`, `entrypoint`, `env_file`, `dns`).
public enum StringOrList: Codable, Hashable, Sendable {
    case string(String)
    case list([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .list(try c.decode([ScalarValue].self).compactMap(\.stringValue))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .list(let l): try c.encode(l)
        }
    }

    public var values: [String] {
        switch self {
        case .string(let s): return [s]
        case .list(let l): return l
        }
    }
}

/// One `KEY=value` (value optional → inherit from host).
public struct KeyValue: Hashable, Sendable {
    public let key: String
    public let value: String?
}

/// `environment` / `labels`: list of `KEY=value` strings **or** a `{KEY: value}` map.
public struct KeyValueMap: Codable, Hashable, Sendable {
    public let pairs: [KeyValue]

    public init(pairs: [KeyValue]) { self.pairs = pairs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([String].self) {
            self.pairs = list.map { item in
                guard let eq = item.firstIndex(of: "=") else { return KeyValue(key: item, value: nil) }
                return KeyValue(key: String(item[..<eq]), value: String(item[item.index(after: eq)...]))
            }
            return
        }
        let map = try c.decode([String: ScalarValue].self)
        self.pairs = map.map { KeyValue(key: $0.key, value: $0.value.stringValue) }
            .sorted { $0.key < $1.key }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(pairs.map { pair in
            if let value = pair.value { return "\(pair.key)=\(value)" }
            return pair.key
        })
    }
}

/// `depends_on`: `[service]` or `{service: {condition: ...}}`.
public struct DependsOn: Codable, Hashable, Sendable {
    public struct Dependency: Hashable, Sendable {
        public let service: String
        public let condition: String?
    }
    public let dependencies: [Dependency]

    private struct ConditionBox: Codable { let condition: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([String].self) {
            self.dependencies = list.map { Dependency(service: $0, condition: nil) }
            return
        }
        let map = try c.decode([String: ConditionBox].self)
        self.dependencies = map.map { Dependency(service: $0.key, condition: $0.value.condition) }
            .sorted { $0.service < $1.service }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(dependencies.map(\.service))
    }
}

/// Service `networks`: `[name]` or `{name: {...}}`.
public struct ServiceNetworks: Codable, Hashable, Sendable {
    public let names: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let list = try? c.decode([String].self) { self.names = list; return }
        let map = try c.decode([String: ScalarValue?].self)
        self.names = map.keys.sorted()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}
