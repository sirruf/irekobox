import Foundation

/// Domain service for `container network`.
public struct NetworkRepository: Sendable {
    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    public func list() async throws -> [Network] {
        try await cli.decode([Network].self, ["network", "ls", "--format", "json"])
    }

    /// `container network create [--subnet <cidr>] <name>`.
    public func create(_ name: String, subnet: String? = nil) async throws {
        var arguments = ["network", "create"]
        if let subnet, !subnet.isEmpty { arguments += ["--subnet", subnet] }
        arguments.append(name)
        try await cli.run(arguments)
    }

    /// `container network create` with every option it has.
    public func create(_ spec: NetworkSpec) async throws {
        var arguments = ["network", "create"]
        if let subnet = spec.subnet { arguments += ["--subnet", subnet] }
        if let subnet = spec.subnetV6 { arguments += ["--subnet-v6", subnet] }
        if spec.hostOnly { arguments.append("--internal") }
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(LabelValue.encode(value))"] }
        for (key, value) in spec.options.sorted(by: { $0.key < $1.key }) { arguments += ["--option", "\(key)=\(value)"] }
        try await cli.run(arguments + [spec.name])
    }

    public func delete(_ name: String) async throws {
        try await cli.run(["network", "delete", name])
    }

    public func prune() async throws {
        try await cli.run(["network", "prune"])
    }
}

/// A network to create.
public struct NetworkSpec: Sendable, Equatable {
    public var name: String
    public var subnet: String?
    public var subnetV6: String?
    /// Host-only: no route out.
    public var hostOnly = false
    public var labels: [String: String] = [:]
    public var options: [String: String] = [:]

    public init(name: String, subnet: String? = nil, subnetV6: String? = nil) {
        self.name = name
        self.subnet = subnet
        self.subnetV6 = subnetV6
    }
}
