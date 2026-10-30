import Foundation

/// A local Kubernetes cluster (`container cluster`, experimental in 1.6):
/// kind node images run as containers, one per node.
public struct Cluster: Hashable, Sendable, Identifiable {
    public struct Node: Hashable, Sendable {
        public let name: String
        public let roles: String
        public let state: String
        public let cpus: Int?
        public let memory: String?
        public let address: String?
        public let ports: String?
    }

    public let name: String
    public let nodes: [Node]

    public var id: String { name }
    public var isRunning: Bool { !nodes.isEmpty && nodes.allSatisfy { $0.state == "running" } }
    public var controlPlane: Node? { nodes.first { $0.roles.contains("control-plane") } }
}

/// `container cluster …`. `list` has no JSON output: its table is parsed by
/// column positions from the header.
public struct ClusterRepository: Sendable {
    private let cli: any ContainerCommanding
    private let stream: CLIStream

    public init(cli: any ContainerCommanding, stream: CLIStream) {
        self.cli = cli
        self.stream = stream
    }

    public func list() async throws -> [Cluster] {
        Self.parse(String(decoding: try await cli.data(["cluster", "list"]), as: UTF8.self))
    }

    static func parse(_ table: String) -> [Cluster] {
        let lines = table.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first else { return [] }
        let names = ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"]
        let starts = names.compactMap { name in header.range(of: name).map { header.distance(from: header.startIndex, to: $0.lowerBound) } }
        guard starts.count == names.count else { return [] }
        func field(_ line: String, _ index: Int) -> String {
            let chars = Array(line)
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : chars.count
            guard start < chars.count else { return "" }
            return String(chars[start..<min(end, chars.count)]).trimmingCharacters(in: .whitespaces)
        }
        var clusters: [(String, [Cluster.Node])] = []
        for line in lines.dropFirst() {
            let cluster = field(line, 0)
            guard !cluster.isEmpty else { continue }
            let node = Cluster.Node(name: field(line, 1), roles: field(line, 2), state: field(line, 3),
                                    cpus: Int(field(line, 4)), memory: field(line, 5).isEmpty ? nil : field(line, 5),
                                    address: field(line, 6).isEmpty ? nil : field(line, 6),
                                    ports: field(line, 7).isEmpty ? nil : field(line, 7))
            if let index = clusters.firstIndex(where: { $0.0 == cluster }) {
                clusters[index].1.append(node)
            } else {
                clusters.append((cluster, [node]))
            }
        }
        return clusters.map { Cluster(name: $0.0, nodes: $0.1) }
    }

    public struct CreateOptions: Sendable {
        public var name: String
        public var cpus: Int?
        /// e.g. "8G".
        public var memory: String?
        public var workers = 0
        /// Write the context here instead of the default kubeconfig.
        public var kubeconfig: String?

        public init(name: String, cpus: Int? = nil, memory: String? = nil, workers: Int = 0, kubeconfig: String? = nil) {
            self.name = name
            self.cpus = cpus
            self.memory = memory
            self.workers = workers
            self.kubeconfig = kubeconfig
        }
    }

    /// Progress lines while the cluster boots (about a minute).
    public func create(_ options: CreateOptions) -> AsyncThrowingStream<String, Error> {
        var arguments = ["cluster", "create", "--name", options.name]
        if let cpus = options.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = options.memory { arguments += ["--memory", memory] }
        if options.workers > 0 { arguments += ["--workers", String(options.workers)] }
        let environment = options.kubeconfig.map { ["KUBECONFIG": $0] } ?? [:]
        return stream.lines(arguments, mergeStderr: true, environment: environment)
    }

    /// `kubeconfig`: the file holding its context (removed from there);
    /// without one the default kubeconfig is rewritten.
    public func delete(_ name: String, kubeconfig: String? = nil) async throws {
        guard let kubeconfig else {
            try await cli.run(["cluster", "delete", "--name", name])
            return
        }
        for try await _ in stream.lines(["cluster", "delete", "--name", name], environment: ["KUBECONFIG": kubeconfig]) {}
    }

    /// Copy a local image into the cluster's containerd (use it with
    /// imagePullPolicy: Never).
    public func loadImage(_ reference: String, into name: String) async throws {
        try await cli.run(["cluster", "load-image", "--name", name, reference])
    }

    public func writeConfig(_ name: String, to path: String) async throws {
        try await cli.run(["cluster", "write-config", "--name", name, "--kubeconfig", path])
    }
}
