import Foundation

/// Whether a service sends traffic where its pods listen. A common slip:
/// nginx listens on 80 but the service (and container port) say 8080; the
/// node port then accepts nothing.
public struct KubePortProblem: Sendable, Equatable, Identifiable, Hashable {
    public let service: KubeService
    /// Index into `service.ports`.
    public let portIndex: Int
    public let target: Int
    /// What the pods do listen on (not loopback-only).
    public let listening: [Int]
    /// Loopback-only listeners on the target: up, but unreachable.
    public let loopbackOnly: Bool

    public var id: String { "\(service.id)#\(portIndex)" }

    /// The one port to point the service at, when there is exactly one.
    public var suggested: Int? { listening.count == 1 ? listening[0] : nil }

    public var message: String {
        if loopbackOnly {
            return "Its pods listen on \(target) only on 127.0.0.1, so the service can't reach them; make the app listen on 0.0.0.0."
        }
        if listening.isEmpty { return "\(service.name) sends to port \(target), and its pods listen on no port." }
        let ports = listening.map(String.init).joined(separator: ", ")
        return "\(service.name) sends to port \(target), but its pods listen on \(ports)."
    }
}

public enum KubePortCheck {
    /// Problems of `service` given what each of its pods listens on.
    public static func problems(_ service: KubeService, listeners: [[ContainerCheckup.Listener]]) -> [KubePortProblem] {
        guard !listeners.isEmpty else { return [] }
        var result: [KubePortProblem] = []
        for (index, port) in service.ports.enumerated() where port.proto.uppercased() == "TCP" {
            guard let target = Int(port.target) else { continue }   // a named port: the pod resolves it
            let open = listeners.allSatisfy { pod in pod.contains { $0.port == target && !$0.isLoopback } }
            if open { continue }
            let loopback = listeners.contains { pod in pod.contains { $0.port == target && $0.isLoopback } }
            let listening = Array(Set(listeners.flatMap { $0 }.filter { !$0.isLoopback }.map(\.port))).sorted()
            result.append(KubePortProblem(service: service, portIndex: index, target: target,
                                          listening: listening, loopbackOnly: loopback))
        }
        return result
    }
}

/// Manifests as `kubectl get -o yaml` gives them, without what the server
/// keeps for itself, ready to edit and apply again.
public enum KubeYAML {
    static let droppedMetadata: Set<String> = ["resourceVersion", "uid", "creationTimestamp", "generation", "selfLink",
                                               "managedFields"]
    static let droppedAnnotations = ["kubectl.kubernetes.io/last-applied-configuration", "deployment.kubernetes.io/revision"]

    public static func editable(_ yaml: String) -> String {
        var output: [String] = []
        var skipDeeperThan: Int?
        var section = ""
        for line in yaml.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let limit = skipDeeperThan {
                if trimmed.isEmpty || indent > limit || (indent == limit && trimmed.hasPrefix("- ")) { continue }
                skipDeeperThan = nil
            }
            if indent == 0 { section = trimmed }
            let key = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            if indent == 0 && key == "status" { skipDeeperThan = 0; continue }
            if section == "metadata:" && indent == 2 && droppedMetadata.contains(key) { skipDeeperThan = 2; continue }
            if section == "metadata:" && indent == 4 && droppedAnnotations.contains(key) { skipDeeperThan = 4; continue }
            output.append(line)
        }
        // An annotations block left empty.
        var text = output.joined(separator: "\n")
        text = text.replacingOccurrences(of: "\n  annotations: {}\n", with: "\n")
        if let range = text.range(of: #"\n  annotations:\n(?=  [a-z])"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "\n")
        }
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}

extension KubeClient {
    /// TCP listeners inside a pod's first container.
    public func listeners(_ pod: KubePod) async throws -> [ContainerCheckup.Listener] {
        let base = arguments(["exec", pod.name, "--namespace", pod.namespace, "--"])
        let data: Data
        if let shell = try? await cli.data(base + ["sh", "-c", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null; true"]) {
            data = shell
        } else {
            data = try await cli.data(base + ["cat", "/proc/net/tcp"])     // images without a shell
        }
        return ContainerCheckup.listeners(procNet: String(decoding: data, as: UTF8.self))
    }

    /// The object's manifest, ready to edit (`resource`: `deployment/web`).
    public func editableYAML(_ resource: String, namespace: String) async throws -> String {
        let data = try await cli.data(arguments(["get", resource, "--namespace", namespace, "--output", "yaml"]))
        return KubeYAML.editable(String(decoding: data, as: UTF8.self))
    }

    /// Point a service port at `target` (and keep the port name as is).
    public func retarget(_ service: KubeService, portIndex: Int, to target: Int) async throws {
        let patch = #"[{"op":"replace","path":"/spec/ports/\#(portIndex)/targetPort","value":\#(target)}]"#
        try await cli.run(arguments(["patch", "service/\(service.name)", "--namespace", service.namespace,
                                     "--type", "json", "--patch", patch]))
    }
}
