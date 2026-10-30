import Foundation

/// What's in a cluster, as the app shows it: workloads with their pods,
/// services and namespaces. Read from `kubectl get … -o json` run inside
/// the control-plane node (every kind node ships kubectl), so neither a
/// kubectl on the Mac nor the kubeconfig's certificates are needed.
public struct KubeSnapshot: Sendable, Equatable {
    public var namespaces: [String]
    public var workloads: [KubeWorkload]
    /// Pods no workload owns.
    public var loosePods: [KubePod]
    public var services: [KubeService]

    public init(namespaces: [String] = [], workloads: [KubeWorkload] = [], loosePods: [KubePod] = [],
                services: [KubeService] = []) {
        self.namespaces = namespaces
        self.workloads = workloads
        self.loosePods = loosePods
        self.services = services
    }

    /// Namespaces Kubernetes and kind run their own parts in.
    public static let systemNamespaces: Set<String> = [
        "kube-system", "kube-public", "kube-node-lease", "local-path-storage",
    ]
}

public struct KubeWorkload: Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case deployment = "Deployment", statefulSet = "StatefulSet", daemonSet = "DaemonSet"

        /// For kubectl: `deployment/web`.
        public var resource: String {
            switch self {
            case .deployment: return "deployment"
            case .statefulSet: return "statefulset"
            case .daemonSet: return "daemonset"
            }
        }
    }

    public let kind: Kind
    public let namespace: String
    public let name: String
    /// Wanted pods (DaemonSet: one per node).
    public let desired: Int
    public let ready: Int
    public let images: [String]
    public let selector: [String: String]
    public var pods: [KubePod]
    /// ConfigMaps, Secrets and volume claims its pods use.
    public var references: [KubeReference] = []

    public var id: String { "\(kind.rawValue)/\(namespace)/\(name)" }
    public var canScale: Bool { kind != .daemonSet }
    public var isSystem: Bool { KubeSnapshot.systemNamespaces.contains(namespace) }
}

public struct KubePod: Sendable, Equatable, Identifiable, Hashable {
    public let namespace: String
    public let name: String
    /// Pending, Running, Succeeded, Failed, Unknown.
    public let phase: String
    public let ready: Bool
    public let restarts: Int
    /// Why a container isn't running: CrashLoopBackOff, ImagePullBackOff, …
    public let reason: String?
    public let message: String?
    public let images: [String]
    public let node: String?
    public let labels: [String: String]
    public let containers: [String]

    public var id: String { "\(namespace)/\(name)" }

    public enum Health: Sendable { case ok, starting, failing, done }

    public var health: Health {
        if phase == "Succeeded" { return .done }
        if let reason, Self.failing.contains(reason) { return .failing }
        if phase == "Failed" { return .failing }
        if phase == "Running" && ready { return .ok }
        return .starting
    }

    static let failing: Set<String> = [
        "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "InvalidImageName",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError", "OOMKilled", "Error",
    ]
}

/// Something a pod template refers to by name (in the workload's namespace).
public struct KubeReference: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case configMap = "ConfigMap", secret = "Secret", volumeClaim = "PVC" }
    public let kind: Kind
    public let name: String

    public var id: String { "\(kind.rawValue)/\(name)" }

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

public struct KubeService: Sendable, Equatable, Identifiable, Hashable {
    public struct Port: Sendable, Equatable, Hashable {
        public let name: String?
        public let port: Int
        public let target: String
        public let nodePort: Int?
        public let proto: String
    }

    public let namespace: String
    public let name: String
    /// ClusterIP, NodePort, LoadBalancer, ExternalName.
    public let type: String
    public let ports: [Port]
    public let selector: [String: String]

    public var id: String { "\(namespace)/\(name)" }

    /// Whether it sends traffic to `pod`.
    public func selects(_ pod: KubePod) -> Bool {
        pod.namespace == namespace && !selector.isEmpty && selector.allSatisfy { pod.labels[$0.key] == $0.value }
    }
}

// MARK: - Decoding

extension KubeSnapshot {
    /// From `kubectl get namespaces,deployments,statefulsets,daemonsets,
    /// replicasets,pods,services -A -o json`.
    public static func decode(_ data: Data) throws -> KubeSnapshot {
        let list = try JSONDecoder().decode(ItemList.self, from: data)
        var namespaces: [String] = []
        var workloads: [KubeWorkload] = []
        var pods: [(KubePod, owner: (kind: String, name: String)?)] = []
        var replicaSetOwner: [String: String] = [:]   // "ns/rs" → deployment
        var services: [KubeService] = []

        for item in list.items {
            let namespace = item.metadata.namespace ?? ""
            let name = item.metadata.name
            switch item.kind {
            case "Namespace":
                namespaces.append(name)
            case "Deployment", "StatefulSet", "DaemonSet":
                let kind = KubeWorkload.Kind(rawValue: item.kind)!
                let desired = kind == .daemonSet ? (item.status?.desiredNumberScheduled ?? 0) : (item.spec?.replicas ?? 1)
                let ready = kind == .daemonSet ? (item.status?.numberReady ?? 0) : (item.status?.readyReplicas ?? 0)
                workloads.append(KubeWorkload(
                    kind: kind, namespace: namespace, name: name, desired: desired, ready: ready,
                    images: item.spec?.template?.spec?.containers.map(\.image) ?? [],
                    selector: item.spec?.selector?.matchLabels ?? [:], pods: [],
                    references: item.spec?.template?.spec.map(references) ?? []))
            case "ReplicaSet":
                if let owner = item.metadata.ownerReferences?.first(where: { $0.kind == "Deployment" }) {
                    replicaSetOwner["\(namespace)/\(name)"] = owner.name
                }
            case "Pod":
                pods.append((pod(item), item.metadata.ownerReferences?.first.map { ($0.kind, $0.name) }))
            case "Service":
                services.append(KubeService(
                    namespace: namespace, name: name, type: item.spec?.type ?? "ClusterIP",
                    ports: (item.spec?.ports ?? []).map {
                        KubeService.Port(name: $0.name, port: $0.port, target: $0.targetPort?.text ?? String($0.port),
                                         nodePort: $0.nodePort, proto: $0.protocol ?? "TCP")
                    },
                    selector: item.spec?.serviceSelector ?? [:]))
            default:
                break
            }
        }

        var loose: [KubePod] = []
        for (pod, owner) in pods {
            var workload: (KubeWorkload.Kind, String)?
            switch owner?.kind {
            case "ReplicaSet": workload = replicaSetOwner["\(pod.namespace)/\(owner!.name)"].map { (.deployment, $0) }
            case "StatefulSet": workload = (.statefulSet, owner!.name)
            case "DaemonSet": workload = (.daemonSet, owner!.name)
            default: workload = nil
            }
            if let workload, let index = workloads.firstIndex(where: {
                $0.kind == workload.0 && $0.name == workload.1 && $0.namespace == pod.namespace
            }) {
                workloads[index].pods.append(pod)
            } else {
                loose.append(pod)
            }
        }
        for index in workloads.indices { workloads[index].pods.sort { $0.name < $1.name } }
        return KubeSnapshot(namespaces: namespaces.sorted(),
                            workloads: workloads.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) },
                            loosePods: loose.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) },
                            services: services.sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) })
    }

    /// ConfigMaps, Secrets and claims a pod template mounts or reads.
    static func references(_ spec: PodSpec) -> [KubeReference] {
        var result: [KubeReference] = []
        for volume in spec.volumes ?? [] {
            if let name = volume.configMap?.name { result.append(.init(kind: .configMap, name: name)) }
            if let name = volume.secret?.secretName { result.append(.init(kind: .secret, name: name)) }
            if let name = volume.persistentVolumeClaim?.claimName { result.append(.init(kind: .volumeClaim, name: name)) }
        }
        for container in spec.containers {
            for source in container.envFrom ?? [] {
                if let name = source.configMapRef?.name { result.append(.init(kind: .configMap, name: name)) }
                if let name = source.secretRef?.name { result.append(.init(kind: .secret, name: name)) }
            }
        }
        var seen: Set<KubeReference> = []
        return result.filter { seen.insert($0).inserted }
    }

    private static func pod(_ item: Item) -> KubePod {
        let statuses = item.status?.containerStatuses ?? []
        let waiting = statuses.lazy.compactMap { $0.state?.waiting ?? $0.state?.terminated }.first
        let unscheduled = item.status?.conditions?.first { $0.type == "PodScheduled" && $0.status == "False" }
        return KubePod(
            namespace: item.metadata.namespace ?? "", name: item.metadata.name,
            phase: item.status?.phase ?? "Unknown",
            ready: !statuses.isEmpty && statuses.allSatisfy(\.ready),
            restarts: statuses.map(\.restartCount).reduce(0, +),
            reason: waiting?.reason ?? unscheduled?.reason ?? item.status?.reason,
            message: waiting?.message ?? unscheduled?.message ?? item.status?.message,
            images: item.spec?.containers?.map(\.image) ?? [],
            node: item.spec?.nodeName,
            labels: item.metadata.labels ?? [:],
            containers: item.spec?.containers?.map(\.name) ?? [])
    }

    // The slice of the Kubernetes JSON we read.
    struct ItemList: Decodable { let items: [Item] }

    struct Item: Decodable {
        let kind: String
        let metadata: Metadata
        let spec: Spec?
        let status: Status?
    }

    struct Metadata: Decodable {
        let name: String
        let namespace: String?
        let labels: [String: String]?
        let ownerReferences: [Owner]?
    }

    struct Owner: Decodable { let kind: String; let name: String }

    struct Spec: Decodable {
        let replicas: Int?
        let selector: Selector?
        let template: Template?
        let containers: [ContainerSpec]?
        let nodeName: String?
        let type: String?
        let ports: [ServicePort]?
        /// A service's selector is a plain map, a workload's has matchLabels.
        let serviceSelector: [String: String]?

        enum CodingKeys: String, CodingKey { case replicas, selector, template, containers, nodeName, type, ports }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            replicas = try c.decodeIfPresent(Int.self, forKey: .replicas)
            template = try c.decodeIfPresent(Template.self, forKey: .template)
            containers = try c.decodeIfPresent([ContainerSpec].self, forKey: .containers)
            nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            ports = try? c.decodeIfPresent([ServicePort].self, forKey: .ports)
            selector = try? c.decodeIfPresent(Selector.self, forKey: .selector)
            serviceSelector = try? c.decodeIfPresent([String: String].self, forKey: .selector)
        }
    }

    struct Selector: Decodable { let matchLabels: [String: String]? }
    struct Template: Decodable { let spec: PodSpec? }
    struct PodSpec: Decodable {
        let containers: [ContainerSpec]
        let volumes: [Volume]?
    }

    struct ContainerSpec: Decodable {
        let name: String
        let image: String
        let envFrom: [EnvFrom]?
    }

    struct Volume: Decodable {
        let configMap: Named?
        let secret: SecretSource?
        let persistentVolumeClaim: Claim?
    }

    struct Named: Decodable { let name: String? }
    struct SecretSource: Decodable { let secretName: String? }
    struct Claim: Decodable { let claimName: String? }

    struct EnvFrom: Decodable {
        let configMapRef: Named?
        let secretRef: Named?
    }

    struct ServicePort: Decodable {
        let name: String?
        let port: Int
        let targetPort: IntOrString?
        let nodePort: Int?
        let `protocol`: String?
    }

    struct IntOrString: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let number = try? c.decode(Int.self) { text = String(number) } else { text = try c.decode(String.self) }
        }
    }

    struct Status: Decodable {
        let replicas: Int?
        let readyReplicas: Int?
        let desiredNumberScheduled: Int?
        let numberReady: Int?
        let phase: String?
        let reason: String?
        let message: String?
        let conditions: [Condition]?
        let containerStatuses: [ContainerStatus]?
    }

    struct Condition: Decodable {
        let type: String
        let status: String
        let reason: String?
        let message: String?
    }

    struct ContainerStatus: Decodable {
        let ready: Bool
        let restartCount: Int
        let state: State?
    }

    struct State: Decodable {
        let waiting: Detail?
        let terminated: Detail?
    }

    struct Detail: Decodable {
        let reason: String?
        let message: String?
    }
}

// MARK: - Client

/// Runs kubectl in a cluster's control-plane node through `container exec`.
public struct KubeClient: Sendable {
    let cli: any ContainerCommanding
    public let node: String

    public init(cli: any ContainerCommanding, node: String) {
        self.cli = cli
        self.node = node
    }

    /// Arguments for `container` that run `kubectl …` in the node.
    public func arguments(_ kubectl: [String], interactive: Bool = false) -> [String] {
        ["exec"] + (interactive ? ["--interactive", "--tty"] : []) + [node, "kubectl"] + kubectl
    }

    public func snapshot() async throws -> KubeSnapshot {
        let data = try await cli.data(arguments(["get", "namespaces,deployments,statefulsets,daemonsets,replicasets,pods,services",
                                                 "--all-namespaces", "--output", "json"]))
        return try KubeSnapshot.decode(data)
    }

    public func scale(_ workload: KubeWorkload, to replicas: Int) async throws {
        try await cli.run(arguments(["scale", "\(workload.kind.resource)/\(workload.name)",
                                     "--namespace", workload.namespace, "--replicas", String(max(0, replicas))]))
    }

    /// New pods, one by one (`kubectl rollout restart`).
    public func restart(_ workload: KubeWorkload) async throws {
        try await cli.run(arguments(["rollout", "restart", "\(workload.kind.resource)/\(workload.name)",
                                     "--namespace", workload.namespace]))
    }

    public func delete(_ workload: KubeWorkload) async throws {
        try await cli.run(arguments(["delete", "\(workload.kind.resource)/\(workload.name)",
                                     "--namespace", workload.namespace, "--wait=false"]))
    }

    public func delete(_ pod: KubePod) async throws {
        try await cli.run(arguments(["delete", "pod/\(pod.name)", "--namespace", pod.namespace, "--wait=false"]))
    }

    /// For a log stream: every container, prefixed, following.
    public func logArguments(_ pod: KubePod, previous: Bool = false) -> [String] {
        arguments(["logs", pod.name, "--namespace", pod.namespace, "--all-containers", "--prefix",
                   "--tail", "500"] + (previous ? ["--previous"] : ["--follow"]))
    }

    /// For a terminal in the pod's first container.
    public func shellArguments(_ pod: KubePod) -> [String] {
        arguments(["exec", "--stdin", "--tty", pod.name, "--namespace", pod.namespace, "--",
                   "env"] + TerminalEnvironment.variables + ["sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"],
                  interactive: true)
    }
}
