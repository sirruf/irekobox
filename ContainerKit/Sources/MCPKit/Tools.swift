import Foundation
import ContainerKit

/// What a tool works with.
public struct ToolContext: Sendable {
    public let engine: any ContainerEngine
    public let cli: ContainerCLI

    public init(engine: any ContainerEngine, cli: ContainerCLI) {
        self.engine = engine
        self.cli = cli
    }
}

/// A tool an assistant can call.
public struct MCPTool: Sendable {
    public let name: String
    public let title: String
    public let description: String
    /// The least access that may call it.
    public let level: AccessLevel
    /// Removes something: asks first when Settings say so.
    public let destructive: Bool
    public let inputSchema: JSON
    /// "restarted shop-api-1", for the activity log.
    public let summary: @Sendable (JSON) -> String
    public let run: @Sendable (JSON, ToolContext) async throws -> String
    /// "delete container shop-db-1": the action as the person at the Mac is
    /// asked to allow it (the summary says what was done).
    public var ask: (@Sendable (JSON) -> String)? = nil
    /// Throws when the target doesn't exist, before anyone is asked to allow
    /// deleting it.
    public var check: (@Sendable (JSON, ToolContext) async throws -> Void)? = nil

    public var definition: JSON {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": .bool(level == .lookOnly),
                "destructiveHint": .bool(destructive),
                "openWorldHint": false,
            ],
        ]
    }
}

public struct ToolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Schemas

enum Schema {
    static func object(_ properties: [String: JSON], required: [String] = []) -> JSON {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSON.string))]
    }
    static func string(_ description: String) -> JSON { ["type": "string", "description": .string(description)] }
    static func integer(_ description: String) -> JSON { ["type": "integer", "description": .string(description)] }
    static func boolean(_ description: String) -> JSON { ["type": "boolean", "description": .string(description)] }
    static func strings(_ description: String) -> JSON {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
}

extension JSON {
    func required(_ key: String) throws -> String {
        guard let value = self[key]?.string, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("Missing \(key).")
        }
        return value
    }

    func strings(_ key: String) -> [String] { self[key]?.array?.compactMap(\.string) ?? [] }
}

// MARK: - The tools

public enum ContainerTools {
    public static let all: [MCPTool] = look + operate + everything

    // MARK: Look

    static let look: [MCPTool] = [
        MCPTool(name: "list_containers", title: "List containers",
                description: "Containers on this Mac with their state, image, published ports and compose project. Machines and Kubernetes nodes are containers too.",
                level: .lookOnly, destructive: false,
                inputSchema: Schema.object(["all": Schema.boolean("Include stopped containers (default true).")]),
                summary: { _ in "listed containers" },
                run: { args, context in
                    let containers = try await context.engine.listContainers(all: args["all"]?.bool ?? true)
                    guard !containers.isEmpty else { return "No containers." }
                    return containers.sorted { $0.id < $1.id }.map(describe).joined(separator: "\n")
                }),
        MCPTool(name: "inspect_container", title: "Inspect a container",
                description: "Everything about one container: image, command, environment, ports, mounts, networks, resources, labels (JSON).",
                level: .lookOnly, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name.")], required: ["name"]),
                summary: { "inspected \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let container = try await context.engine.inspectContainer(try args.required("name"))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return String(decoding: try encoder.encode(container), as: UTF8.self)
                }),
        MCPTool(name: "container_logs", title: "Read a container's logs",
                description: "The last lines a container wrote (stdout and stderr).",
                level: .lookOnly, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name."),
                                            "lines": Schema.integer("How many of the last lines (default 100, at most 2000).")],
                                           required: ["name"]),
                summary: { "read logs of \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    let keep = min(2000, max(1, args["lines"]?.int ?? 100))
                    var lines: [String] = []
                    for try await line in context.engine.containerLogs(name, follow: false) {
                        lines.append(line)
                        if lines.count > keep { lines.removeFirst(lines.count - keep) }
                    }
                    return lines.isEmpty ? "No output." : lines.joined(separator: "\n")
                }),
        MCPTool(name: "container_stats", title: "Resource use of a container",
                description: "CPU (over one second), memory used and its limit, network and disk totals, process count.",
                level: .lookOnly, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name.")], required: ["name"]),
                summary: { "read stats of \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    let first = try await context.engine.containerStats(name)
                    try await Task.sleep(for: .seconds(1))
                    let second = try await context.engine.containerStats(name)
                    let cpu = second.cpuPercent(since: first, interval: 1)
                    return """
                    CPU: \(String(format: "%.1f", cpu))% of one core
                    Memory: \(bytes(second.memoryUsageBytes)) of \(bytes(second.memoryLimitBytes))
                    Network: \(bytes(second.networkRxBytes)) in, \(bytes(second.networkTxBytes)) out (since start)
                    Disk: \(bytes(second.blockReadBytes)) read, \(bytes(second.blockWriteBytes)) written
                    Processes: \(second.numProcesses)
                    """
                }),
        MCPTool(name: "list_images", title: "List images",
                description: "Images on this Mac with their size.",
                level: .lookOnly, destructive: false, inputSchema: Schema.object([:]),
                summary: { _ in "listed images" },
                run: { _, context in
                    let images = try await context.engine.listImages()
                    return images.isEmpty ? "No images." : images.map { "\($0.reference)  \(bytes(Int64($0.totalSize)))" }.sorted().joined(separator: "\n")
                }),
        MCPTool(name: "list_volumes", title: "List volumes",
                description: "Named volumes: storage that outlives containers.",
                level: .lookOnly, destructive: false, inputSchema: Schema.object([:]),
                summary: { _ in "listed volumes" },
                run: { _, context in
                    let volumes = try await context.engine.listVolumes()
                    return volumes.isEmpty ? "No volumes." : volumes.map(\.name).sorted().joined(separator: "\n")
                }),
        MCPTool(name: "list_networks", title: "List networks",
                description: "Networks and their subnets. Containers on the same network reach each other by name.",
                level: .lookOnly, destructive: false, inputSchema: Schema.object([:]),
                summary: { _ in "listed networks" },
                run: { _, context in
                    let networks = try await context.engine.listNetworks()
                    return networks.map { "\($0.name)  \($0.subnet ?? "")" }.sorted().joined(separator: "\n")
                }),
        MCPTool(name: "system_status", title: "Engine status",
                description: "Whether the container engine runs, its version, and disk use.",
                level: .lookOnly, destructive: false, inputSchema: Schema.object([:]),
                summary: { _ in "checked the engine" },
                run: { _, context in
                    guard let status = try await context.engine.systemStatus() else { return "The engine isn't running." }
                    var text = "Engine: \(status.status)"
                    if let usage = try? await context.engine.diskUsage() {
                        let used = usage.images.sizeInBytes + usage.containers.sizeInBytes + usage.volumes.sizeInBytes
                        let free = usage.images.reclaimableInBytes + usage.containers.reclaimableInBytes + usage.volumes.reclaimableInBytes
                        text += "\nDisk: \(bytes(used)) used, \(bytes(free)) could be freed"
                        text += "\n\(usage.containers.total) containers (\(usage.containers.active) running), \(usage.images.total) images, \(usage.volumes.total) volumes"
                    }
                    return text
                }),
        MCPTool(name: "kubectl_get", title: "Look into a Kubernetes cluster",
                description: "kubectl get or describe in a local cluster: pods, deployments, services, events, nodes…",
                level: .lookOnly, destructive: false,
                inputSchema: Schema.object(["cluster": Schema.string("Cluster name (its control-plane container)."),
                                            "verb": ["type": "string", "enum": ["get", "describe", "logs", "top"],
                                                     "description": "kubectl verb (default get)."],
                                            "resource": Schema.string("What to show, e.g. pods, deployment/web, svc."),
                                            "namespace": Schema.string("Namespace; empty for all.")],
                                           required: ["cluster", "resource"]),
                summary: { "kubectl \($0["verb"]?.string ?? "get") \($0["resource"]?.string ?? "") in \($0["cluster"]?.string ?? "")" },
                run: { args, context in
                    let verb = args["verb"]?.string ?? "get"
                    guard ["get", "describe", "logs", "top"].contains(verb) else { throw ToolError("Only get, describe, logs and top.") }
                    var command = ["exec", try args.required("cluster"), "kubectl", verb]
                    command += try args.required("resource").split(separator: " ").map(String.init)
                    if let namespace = args["namespace"]?.string, !namespace.isEmpty { command += ["-n", namespace] }
                    else if verb == "get" || verb == "top" { command.append("-A") }
                    if verb == "get" { command += ["-o", "wide"] }
                    return String(decoding: try await context.cli.data(command), as: UTF8.self)
                }),
    ]

    // MARK: Operate

    static let operate: [MCPTool] = [
        MCPTool(name: "start_container", title: "Start a container", description: "Start a stopped container.",
                level: .operate, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name.")], required: ["name"]),
                summary: { "started \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    try await context.engine.startContainer(name)
                    return "Started \(name)."
                }),
        MCPTool(name: "stop_container", title: "Stop a container", description: "Stop a running container (it stays, with its files).",
                level: .operate, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name.")], required: ["name"]),
                summary: { "stopped \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    try await context.engine.stopContainer(name)
                    return "Stopped \(name)."
                }),
        MCPTool(name: "restart_container", title: "Restart a container", description: "Stop and start a container.",
                level: .operate, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name.")], required: ["name"]),
                summary: { "restarted \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    try await context.engine.stopContainer(name)
                    try await context.engine.startContainer(name)
                    return "Restarted \(name)."
                }),
        MCPTool(name: "pull_image", title: "Pull an image", description: "Download an image, e.g. postgres:17-alpine.",
                level: .operate, destructive: false,
                inputSchema: Schema.object(["image": Schema.string("Image reference.")], required: ["image"]),
                summary: { "pulled \($0["image"]?.string ?? "")" },
                run: { args, context in
                    let image = try args.required("image")
                    try await context.engine.pullImage(image)
                    return "Pulled \(image)."
                }),
        MCPTool(name: "scale_deployment", title: "Scale a Kubernetes deployment",
                description: "Set how many copies of a deployment the cluster keeps running.",
                level: .operate, destructive: false,
                inputSchema: Schema.object(["cluster": Schema.string("Cluster name."),
                                            "namespace": Schema.string("Namespace (default \"default\")."),
                                            "name": Schema.string("Deployment name."),
                                            "replicas": Schema.integer("How many copies.")],
                                           required: ["cluster", "name", "replicas"]),
                summary: { "scaled \($0["name"]?.string ?? "") to \($0["replicas"]?.int ?? 0)" },
                run: { args, context in
                    guard let replicas = args["replicas"]?.int, replicas >= 0 else { throw ToolError("replicas must be 0 or more.") }
                    let name = try args.required("name")
                    let namespace = args["namespace"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
                    try await context.cli.run(["exec", try args.required("cluster"), "kubectl", "scale", "deployment/\(name)",
                                               "-n", namespace, "--replicas=\(replicas)"])
                    return "\(name) now keeps \(replicas) cop\(replicas == 1 ? "y" : "ies")."
                }),
    ]

    // MARK: Everything

    static let everything: [MCPTool] = [
        MCPTool(name: "run_container", title: "Run a container",
                description: "Start a new container from an image, in the background.",
                level: .everything, destructive: false,
                inputSchema: Schema.object(["image": Schema.string("Image, e.g. nginx:alpine."),
                                            "name": Schema.string("Container name (optional)."),
                                            "ports": Schema.strings("Published ports, host:container, e.g. 8080:80."),
                                            "env": Schema.strings("Environment, KEY=value."),
                                            "volumes": Schema.strings("Mounts, volume-or-folder:/path[:ro]."),
                                            "command": Schema.strings("Command and arguments instead of the image's.")],
                                           required: ["image"]),
                summary: { "ran \($0["image"]?.string ?? "")" + ($0["name"]?.string.map { " as \($0)" } ?? "") },
                run: { args, context in
                    var arguments = ["-d"]
                    if let name = args["name"]?.string, !name.isEmpty { arguments += ["--name", name] }
                    for port in args.strings("ports") { arguments += ["--publish", port] }
                    for variable in args.strings("env") { arguments += ["--env", variable] }
                    for volume in args.strings("volumes") { arguments += ["--volume", volume] }
                    arguments.append(try args.required("image"))
                    arguments += args.strings("command")
                    try await context.engine.runContainer(arguments)
                    return "Started a container from \(try args.required("image"))."
                }),
        MCPTool(name: "exec_command", title: "Run a command inside a container",
                description: "Run one command in a running container and return its output, e.g. [\"ls\", \"/app\"].",
                level: .everything, destructive: false,
                inputSchema: Schema.object(["name": Schema.string("Container name."),
                                            "command": Schema.strings("Command and arguments.")],
                                           required: ["name", "command"]),
                summary: { "ran \($0.strings("command").joined(separator: " ")) in \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let command = args.strings("command")
                    guard !command.isEmpty else { throw ToolError("Missing command.") }
                    let output = try await context.engine.execute(try args.required("name"), command: command)
                    return String(decoding: output, as: UTF8.self)
                }),
        MCPTool(name: "kubectl_apply", title: "Apply Kubernetes YAML",
                description: "kubectl apply -f - in a local cluster with the given manifests.",
                level: .everything, destructive: false,
                inputSchema: Schema.object(["cluster": Schema.string("Cluster name."),
                                            "yaml": Schema.string("One or more manifests.")],
                                           required: ["cluster", "yaml"]),
                summary: { "applied YAML to \($0["cluster"]?.string ?? "")" },
                run: { args, context in
                    try await context.cli.run(["exec", "-i", try args.required("cluster"), "kubectl", "apply", "-f", "-"],
                                              input: Data(try args.required("yaml").utf8))
                    return "Applied."
                }),
        MCPTool(name: "delete_container", title: "Delete a container",
                description: "Delete a container (stopping it first with force). Its volumes stay.",
                level: .everything, destructive: true,
                inputSchema: Schema.object(["name": Schema.string("Container name."),
                                            "force": Schema.boolean("Stop it first if it runs (default true).")],
                                           required: ["name"]),
                summary: { "deleted container \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    try await context.engine.deleteContainer(name, force: args["force"]?.bool ?? true)
                    return "Deleted \(name)."
                },
                ask: { "delete container \($0["name"]?.string ?? "")" },
                check: { args, context in
                    let name = try args.required("name")
                    guard (try? await context.engine.inspectContainer(name)) != nil else {
                        throw ToolError("No container named \(name).")
                    }
                }),
        MCPTool(name: "delete_image", title: "Delete an image", description: "Delete an image no container needs.",
                level: .everything, destructive: true,
                inputSchema: Schema.object(["image": Schema.string("Image reference.")], required: ["image"]),
                summary: { "deleted image \($0["image"]?.string ?? "")" },
                run: { args, context in
                    let image = try args.required("image")
                    try await context.engine.deleteImage(image, force: false)
                    return "Deleted \(image)."
                },
                ask: { "delete image \($0["image"]?.string ?? "")" },
                check: { args, context in
                    let image = try args.required("image")
                    guard (try? await context.engine.inspectImage(image)) != nil else {
                        throw ToolError("No image \(image) on this Mac.")
                    }
                }),
        MCPTool(name: "delete_volume", title: "Delete a volume", description: "Delete a volume and the data in it.",
                level: .everything, destructive: true,
                inputSchema: Schema.object(["name": Schema.string("Volume name.")], required: ["name"]),
                summary: { "deleted volume \($0["name"]?.string ?? "")" },
                run: { args, context in
                    let name = try args.required("name")
                    try await context.engine.deleteVolume(name)
                    return "Deleted volume \(name)."
                },
                ask: { "delete volume \($0["name"]?.string ?? "") and the data in it" },
                check: { args, context in
                    let name = try args.required("name")
                    guard try await context.engine.listVolumes().contains(where: { $0.name == name }) else {
                        throw ToolError("No volume named \(name).")
                    }
                }),
    ]

    // MARK: - Text

    static func describe(_ container: Container) -> String {
        let configuration = container.configuration
        var parts = [container.id, container.state.rawValue, configuration.image.reference]
        let ports = (configuration.publishedPorts ?? []).map { "\($0.hostPort)->\($0.containerPort)" }
        if !ports.isEmpty { parts.append("ports " + ports.joined(separator: ",")) }
        if let project = configuration.labels["com.docker.compose.project"] ?? configuration.labels["com.irekobox.stack"] {
            parts.append("project \(project)")
        }
        return parts.joined(separator: "  ")
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
