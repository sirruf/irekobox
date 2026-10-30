import Foundation

/// The manifests for "run this image in the cluster": a Deployment, and a
/// Service when it listens on a port (NodePort to reach it from the Mac).
public struct KubeDeployment: Sendable, Equatable {
    public enum Exposure: String, Sendable, CaseIterable {
        /// No Service.
        case none
        /// ClusterIP: other pods reach it by name.
        case cluster
        /// NodePort: also this Mac, at the node's address.
        case mac
    }

    public var name: String
    public var namespace: String
    public var image: String
    public var replicas: Int
    public var port: Int?
    public var exposure: Exposure
    /// A fixed node port (30000–32767); nil lets Kubernetes pick.
    public var nodePort: Int?
    public var environment: [(key: String, value: String)]
    /// Add the Namespace too (it doesn't exist yet).
    public var createNamespace: Bool

    public init(name: String, namespace: String = "default", image: String, replicas: Int = 1, port: Int? = nil,
                exposure: Exposure = .none, nodePort: Int? = nil, environment: [(key: String, value: String)] = [],
                createNamespace: Bool = false) {
        self.name = name
        self.namespace = namespace
        self.image = image
        self.replicas = replicas
        self.port = port
        self.exposure = exposure
        self.nodePort = nodePort
        self.environment = environment
        self.createNamespace = createNamespace
    }

    public static func == (a: KubeDeployment, b: KubeDeployment) -> Bool {
        a.yaml == b.yaml
    }

    /// Kubernetes object names: lowercase letters, digits, hyphens; ≤ 63.
    public static func isValidName(_ name: String) -> Bool {
        name.count <= 63 && name.wholeMatch(of: /[a-z0-9]([a-z0-9-]*[a-z0-9])?/) != nil
    }

    /// A name from an image: `ghcr.io/me/web-app:1.2` → `web-app`.
    public static func suggestedName(for image: String) -> String {
        let last = image.split(separator: "/").last.map(String.init) ?? image
        let base = last.split(separator: ":").first.map(String.init) ?? last
        var name = base.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? String($0) : "-" }.joined()
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = String(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
        return name.isEmpty ? "app" : name
    }

    public var yaml: String {
        var documents: [String] = []
        if createNamespace {
            documents.append("""
            apiVersion: v1
            kind: Namespace
            metadata:
              name: \(namespace)
            """)
        }
        var container = """
              - name: \(name)
                image: \(quoted(image))
                imagePullPolicy: IfNotPresent
        """
        if let port {
            container += "\n        ports:\n          - containerPort: \(port)"
        }
        if !environment.isEmpty {
            container += "\n        env:"
            for variable in environment {
                container += "\n          - name: \(variable.key)\n            value: \(quoted(variable.value))"
            }
        }
        documents.append("""
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: \(name)
          namespace: \(namespace)
          labels:
            app: \(name)
        spec:
          replicas: \(replicas)
          selector:
            matchLabels:
              app: \(name)
          template:
            metadata:
              labels:
                app: \(name)
            spec:
              containers:
        \(container)
        """)
        if let port, exposure != .none {
            var ports = "    - port: \(port)\n      targetPort: \(port)"
            if exposure == .mac, let nodePort { ports += "\n      nodePort: \(nodePort)" }
            documents.append("""
            apiVersion: v1
            kind: Service
            metadata:
              name: \(name)
              namespace: \(namespace)
            spec:
              type: \(exposure == .mac ? "NodePort" : "ClusterIP")
              selector:
                app: \(name)
              ports:
            \(ports)
            """)
        }
        return documents.joined(separator: "\n---\n") + "\n"
    }

    /// The same with kubectl, one command per line.
    public var kubectlCommands: [String] {
        var commands: [String] = []
        if createNamespace { commands.append("kubectl create namespace \(namespace)") }
        var create = "kubectl create deployment \(name) --image=\(image) --replicas=\(replicas)"
        if let port { create += " --port=\(port)" }
        commands.append(create + " -n \(namespace)")
        for variable in environment {
            commands.append("kubectl set env deployment/\(name) \(variable.key)=\(variable.value) -n \(namespace)")
        }
        if let port, exposure != .none {
            commands.append("kubectl expose deployment \(name) --port=\(port) --type=\(exposure == .mac ? "NodePort" : "ClusterIP") -n \(namespace)")
        }
        return commands
    }

    /// The manifests with a comment before the lines a newcomer asks about.
    public var annotatedYAML: String {
        let notes: [(prefix: String, note: String)] = [
            ("kind: Namespace", String(localized: "A namespace: a folder that keeps this project's objects together.")),
            ("kind: Deployment", String(localized: "A Deployment keeps the pods below running and replaces any that stop.")),
            ("  replicas:", String(localized: "How many copies (pods) run at once.")),
            ("  selector:", String(localized: "Which pods belong to it: the ones with these labels.")),
            ("  template:", String(localized: "The pod to make copies of.")),
            ("        image:", String(localized: "The packaged app.")),
            ("        imagePullPolicy:", String(localized: "Use the image already in the cluster if it's there.")),
            ("          - containerPort:", String(localized: "The port the app listens on (for information; the Service is what routes).")),
            ("kind: Service", String(localized: "A Service: a stable name and port in front of the pods.")),
            ("  type: NodePort", String(localized: "NodePort: also opens a port (30000-32767) on the node, which this Mac can reach.")),
            ("  type: ClusterIP", String(localized: "ClusterIP: reachable only by other apps in the cluster, by name.")),
            ("    - port:", String(localized: "The port the Service answers on...")),
            ("      targetPort:", String(localized: "...and the pod port it forwards to.")),
        ]
        var lines: [String] = []
        for line in yaml.components(separatedBy: "\n") {
            if let note = notes.first(where: { line.hasPrefix($0.prefix) }) {
                let indent = String(line.prefix { $0 == " " })
                lines.append("\(indent)# \(note.note)")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Quote when YAML would read it as something else (numbers, booleans, `:`…).
    private func quoted(_ value: String) -> String {
        let plain = value.wholeMatch(of: /[A-Za-z_\/][A-Za-z0-9_.\/@-]*(:[A-Za-z0-9_.-]+)?/) != nil
        let keyword = ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(value.lowercased())
        if plain && !keyword { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension KubeClient {
    /// `kubectl apply -f -` with `yaml` on standard input.
    public func apply(_ yaml: String) async throws {
        try await cli.run(["exec", "--interactive", node, "kubectl", "apply", "-f", "-"], input: Data(yaml.utf8))
    }

    /// `kubectl apply --dry-run=server`: the server checks it, nothing changes.
    public func check(_ yaml: String) async throws {
        try await cli.run(["exec", "--interactive", node, "kubectl", "apply", "--dry-run=server", "-f", "-"],
                          input: Data(yaml.utf8))
    }

    public func delete(_ service: KubeService) async throws {
        try await cli.run(arguments(["delete", "service/\(service.name)", "--namespace", service.namespace,
                                     "--wait=false"]))
    }
}
