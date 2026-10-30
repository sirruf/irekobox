import Foundation
import Yams
import Observation
import ContainerKit

/// One cluster's contents, refreshed while its page is open, and the
/// actions on them. kubectl runs inside the control-plane node.
@MainActor
@Observable
final class ClusterModel {
    let name: String
    let client: KubeClient
    private(set) var snapshot: KubeSnapshot?
    private(set) var busy: Set<String> = []
    var error: String?
    var notice: String?

    /// nil: every namespace with apps in it.
    var namespace: String?
    var showSystem = false

    init(name: String, node: String, cli: any ContainerCommanding) {
        self.name = name
        client = KubeClient(cli: cli, node: node)
    }

    /// Service ports that lead nowhere, by service id.
    private(set) var portProblems: [String: [KubePortProblem]] = [:]
    /// What each pod listens on, and when it was read (pods change rarely).
    @ObservationIgnored private var listening: [String: (date: Date, listeners: [ContainerCheckup.Listener])] = [:]

    func refresh() async {
        do {
            snapshot = try await client.snapshot()
            error = nil
            await checkPorts()
        } catch {
            // Still booting, or stopped: say so once, keep the last view.
            self.error = String(localized: "Can't reach the cluster: \(error.localizedDescription)")
        }
    }

    /// Look inside the running pods behind the shown services.
    private func checkPorts() async {
        guard let snapshot else { return }
        let pods = snapshot.workloads.flatMap(\.pods) + snapshot.loosePods
        var result: [String: [KubePortProblem]] = [:]
        for service in services where !service.selector.isEmpty {
            var listeners: [[ContainerCheckup.Listener]] = []
            for pod in pods where service.selects(pod) && pod.phase == "Running" {
                if let cached = listening[pod.id], Date().timeIntervalSince(cached.date) < 60 {
                    listeners.append(cached.listeners)
                } else if let read = try? await client.listeners(pod) {
                    listening[pod.id] = (Date(), read)
                    listeners.append(read)
                }
            }
            let problems = KubePortCheck.problems(service, listeners: listeners)
            if !problems.isEmpty { result[service.id] = problems }
        }
        let live = Set(pods.map(\.id))
        listening = listening.filter { live.contains($0.key) }
        portProblems = result
    }

    /// For manifests about to be applied: services whose target port none of
    /// the running pods they select listens on ("No pod listens on 8080 —
    /// web listens on 80").
    func portWarnings(in yaml: String) async -> [String] {
        guard let snapshot, let documents = try? Yams.load_all(yaml: yaml) else { return [] }
        let pods = (snapshot.workloads.flatMap(\.pods) + snapshot.loosePods).filter { $0.phase == "Running" }
        var warnings: [String] = []
        for case let document as [String: Any] in documents where document["kind"] as? String == "Service" {
            let metadata = document["metadata"] as? [String: Any] ?? [:]
            let spec = document["spec"] as? [String: Any] ?? [:]
            let namespace = metadata["namespace"] as? String ?? "default"
            let selector = (spec["selector"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
            guard !selector.isEmpty else { continue }
            let selected = pods.filter { pod in pod.namespace == namespace && selector.allSatisfy { pod.labels[$0.key] == $0.value } }
            guard let pod = selected.first else { continue }
            let listeners: [ContainerCheckup.Listener]
            if let cached = listening[pod.id] {
                listeners = cached.listeners
            } else if let read = try? await client.listeners(pod) {
                listening[pod.id] = (Date(), read)
                listeners = read
            } else { continue }
            let open = Set(listeners.filter { !$0.isLoopback }.map(\.port))
            guard !open.isEmpty else { continue }
            let app = pod.labels["app"] ?? pod.labels["app.kubernetes.io/name"] ?? pod.name
            for case let port as [String: Any] in spec["ports"] as? [Any] ?? [] {
                guard let target = (port["targetPort"] as? Int) ?? (port["targetPort"] == nil ? port["port"] as? Int : nil),
                      !open.contains(target) else { continue }
                let ports = open.sorted().map(String.init).joined(separator: ", ")
                warnings.append(String(localized: "No pod listens on \(String(target)) — \(app) listens on \(ports)"))
            }
        }
        return warnings
    }

    /// Point the service at the port its pods listen on.
    func fix(_ problem: KubePortProblem) async {
        guard let target = problem.suggested else { return }
        await perform(problem.service.id) {
            try await client.retarget(problem.service, portIndex: problem.portIndex, to: target)
        }
        if error == nil { notice = String(localized: "\(problem.service.name) now sends to port \(String(target)).") }
    }

    /// The manifest of `resource` (`deployment/web`) to edit.
    func editableYAML(_ resource: String, namespace: String) async -> String? {
        do {
            return try await client.editableYAML(resource, namespace: namespace)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func shown(_ namespace: String) -> Bool {
        if let selected = self.namespace { return namespace == selected }
        return showSystem || !KubeSnapshot.systemNamespaces.contains(namespace)
    }

    var workloads: [KubeWorkload] { snapshot?.workloads.filter { shown($0.namespace) } ?? [] }
    var loosePods: [KubePod] { snapshot?.loosePods.filter { shown($0.namespace) } ?? [] }
    var services: [KubeService] { snapshot?.services.filter { shown($0.namespace) && $0.name != "kubernetes" } ?? [] }

    /// Namespaces to pick from: apps' first, system ones when shown.
    var namespaces: [String] {
        (snapshot?.namespaces ?? []).filter { showSystem || !KubeSnapshot.systemNamespaces.contains($0) }
    }

    var allPods: [KubePod] {
        (snapshot?.workloads.flatMap(\.pods) ?? []) + (snapshot?.loosePods ?? [])
    }

    func services(for workload: KubeWorkload) -> [KubeService] {
        (snapshot?.services ?? []).filter { service in workload.pods.contains(where: service.selects) }
    }

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    private func perform(_ id: String, _ action: () async throws -> Void) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func scale(_ workload: KubeWorkload, to replicas: Int) async {
        await perform(workload.id) { try await client.scale(workload, to: replicas) }
    }

    func restart(_ workload: KubeWorkload) async {
        await perform(workload.id) { try await client.restart(workload) }
        if error == nil { notice = String(localized: "Restarting \(workload.name): new pods replace the old one by one.") }
    }

    func delete(_ workload: KubeWorkload) async {
        await perform(workload.id) { try await client.delete(workload) }
    }

    func delete(_ service: KubeService) async {
        await perform(service.id) { try await client.delete(service) }
    }

    /// `kubectl apply` the manifests; the error says what the server refused.
    func apply(_ yaml: String) async -> Bool {
        await perform("apply") { try await client.apply(yaml) }
        if error == nil { notice = String(localized: "Applied.") }
        return error == nil
    }

    // MARK: - Run an app

    private(set) var runSteps: [RunAppStep] = []

    private func step(_ id: String, _ state: RunAppStep.State) {
        if let index = runSteps.firstIndex(where: { $0.id == id }) { runSteps[index].state = state }
    }

    /// Load the image if it's on this Mac, start the Deployment, wait for a
    /// pod, find the port it listens on, then make it reachable: the
    /// beginner never has to know the port.
    func runApp(_ plan: RunAppPlan, localImage: Bool, clusters: ClustersModel, nodeAddress: String?) async -> RunAppResult? {
        let wantsService = plan.kind != .worker
        runSteps = [
            RunAppStep(id: "load", title: localImage ? String(localized: "Copy \(plan.image) from this Mac into the cluster")
                                                    : String(localized: "The cluster pulls \(plan.image) itself")),
            RunAppStep(id: "deploy", title: String(localized: "Create the Deployment \(plan.name)")),
            RunAppStep(id: "pod", title: String(localized: "Wait for its first pod to start")),
            RunAppStep(id: "port", title: wantsService ? String(localized: "Find the port the app listens on")
                                                  : String(localized: "No port needed for a worker")),
            RunAppStep(id: "service", title: wantsService ? String(localized: "Create the Service \(plan.name)")
                                                     : String(localized: "No Service for a worker")),
        ]
        if localImage {
            step("load", .running)
            await clusters.load(plan.image, into: name)
            if let error = clusters.error { step("load", .failed(error)); return nil }
            step("load", .done(nil))
        } else {
            step("load", .skipped)
        }

        var deployment = KubeDeployment(name: plan.name, namespace: plan.namespace, image: plan.image,
                                        replicas: plan.replicas, port: plan.port, exposure: .none,
                                        environment: plan.environment,
                                        createNamespace: !(snapshot?.namespaces.contains(plan.namespace) ?? false))
        step("deploy", .running)
        do { try await client.apply(deployment.yaml) } catch { step("deploy", .failed(error.localizedDescription)); return nil }
        step("deploy", .done(nil))

        step("pod", .running)
        var pod: KubePod?
        for _ in 0..<60 {
            await refresh()
            let pods = snapshot?.workloads.first { $0.kind == .deployment && $0.name == plan.name && $0.namespace == plan.namespace }?.pods ?? []
            if let failing = pods.first(where: { $0.health == .failing }) {
                step("pod", .failed(PodAdvice.text(for: failing) ?? failing.reason ?? String(localized: "It failed to start.")))
                return nil
            }
            if let running = pods.first(where: { $0.phase == "Running" }) { pod = running; break }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let pod else { step("pod", .failed(String(localized: "No pod started within two minutes; its card says why."))); return nil }
        step("pod", .done(pod.name))

        guard wantsService else {
            step("port", .skipped)
            step("service", .skipped)
            return RunAppResult(deployment: deployment, port: nil, url: nil, internalAddress: nil, detected: false)
        }

        step("port", .running)
        var port = plan.port
        var detected = false
        var listening: [Int] = []
        for _ in 0..<10 {
            listening = Array(Set(((try? await client.listeners(pod)) ?? []).filter { !$0.isLoopback }.map(\.port))).sorted()
            if !listening.isEmpty { break }
            try? await Task.sleep(for: .seconds(2))
        }
        if let wanted = port, !listening.isEmpty, !listening.contains(wanted) {
            let ports = listening.map(String.init).joined(separator: ", ")
            step("port", .done(String(localized: "You said \(String(wanted)), but it listens on \(ports); using \(String(listening[0])).")))
            port = listening[0]
            detected = true
        } else if port == nil {
            guard let first = Self.likelyPort(listening) else {
                step("port", .failed(String(localized: "It doesn't listen on any port. If nothing should connect to it, run it as a worker.")))
                return nil
            }
            port = first
            detected = true
            if listening.count > 1 {
                let others = listening.dropFirst().map(String.init).joined(separator: ", ")
                step("port", .done(String(localized: "It listens on \(String(first)) (also \(others))")))
            } else {
                step("port", .done(String(localized: "It listens on \(String(first))")))
            }
        } else {
            step("port", .done(String(localized: "It listens on \(String(port!))")))
        }

        step("service", .running)
        deployment.port = port
        deployment.exposure = plan.audience == .mac && plan.kind == .web ? .mac : .cluster
        deployment.createNamespace = false
        do { try await client.apply(deployment.yaml) } catch { step("service", .failed(error.localizedDescription)); return nil }
        await refresh()
        let service = snapshot?.services.first { $0.name == plan.name && $0.namespace == plan.namespace }
        let nodePort = service?.ports.first?.nodePort
        let url = nodePort.flatMap { node in nodeAddress.flatMap { URL(string: "http://\($0):\(node)") } }
        step("service", .done(nodePort.map { String(localized: "Node port \(String($0))") } ?? String(localized: "Inside the cluster")))
        return RunAppResult(deployment: deployment, port: port, url: url,
                            internalAddress: port.map { "\(plan.name).\(plan.namespace):\($0)" }, detected: detected)
    }

    /// The port people mean when an app listens on several.
    static func likelyPort(_ ports: [Int]) -> Int? {
        let usual = [80, 8080, 3000, 8000, 5000, 443, 8443, 5432, 6379, 3306, 27017]
        return usual.first(where: ports.contains) ?? ports.first
    }

    /// Check manifests on the server without changing anything.
    func check(_ yaml: String) async -> String? {
        do {
            try await client.check(yaml)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func delete(_ pod: KubePod) async {
        await perform(pod.id) { try await client.delete(pod) }
    }
}

/// "Run an app": what the beginner asked for, in their words.
struct RunAppPlan {
    enum Kind: String { case web, internalService, worker }
    enum Audience: String { case mac, cluster }

    var image = ""
    var name = ""
    var namespace = "default"
    var kind: Kind = .web
    var audience: Audience = .mac
    var replicas = 1
    /// Empty: found by looking inside the first pod.
    var port: Int?
    var environment: [(key: String, value: String)] = []
}

/// One step of running an app, as the progress list shows it.
struct RunAppStep: Identifiable {
    enum State: Equatable { case waiting, running, done(String?), failed(String), skipped }
    let id: String
    let title: String
    var state: State = .waiting
}

/// What came of it, explained.
struct RunAppResult {
    let deployment: KubeDeployment
    let port: Int?
    /// http://node:nodePort, when this Mac can open it.
    let url: URL?
    /// name.namespace:port, for other apps.
    let internalAddress: String?
    /// Port found by looking inside the pod (not typed by the user).
    let detected: Bool
}

/// What a pod's trouble means and what to do about it.
enum PodAdvice {
    static func text(for pod: KubePod) -> String? {
        guard let reason = pod.reason else { return nil }
        switch reason {
        case "ErrImagePull", "ImagePullBackOff":
            if let image = pod.images.first {
                return String(localized: "Kubernetes can't pull \(image). An image built or pulled on this Mac isn't in the cluster: load it (Load Image…) and set imagePullPolicy: IfNotPresent (or Never).")
            }
            return String(localized: "Kubernetes can't pull the image. An image built or pulled on this Mac isn't in the cluster: load it (Load Image…) and set imagePullPolicy: IfNotPresent (or Never).")
        case "InvalidImageName":
            return String(localized: "The image name isn't valid.")
        case "CrashLoopBackOff":
            return String(localized: "It starts and exits again and again; its logs say why. Kubernetes waits longer between tries each time.")
        case "OOMKilled":
            return String(localized: "It ran out of memory: raise its memory limit.")
        case "CreateContainerConfigError":
            return String(localized: "A ConfigMap or Secret it needs is missing: \(pod.message ?? "")")
        case "Unschedulable":
            let why = pod.message ?? String(localized: "not enough CPU or memory")
            return String(localized: "No node can take it: \(why). Give the cluster more, or ask for less.")
        case "ContainerCreating", "PodInitializing":
            return String(localized: "Starting: pulling the image and setting up.")
        default:
            return pod.message
        }
    }

    /// Images the pod needs that are on this Mac (from `local` references).
    static func loadable(_ pod: KubePod, local: [String]) -> String? {
        guard pod.reason == "ErrImagePull" || pod.reason == "ImagePullBackOff" else { return nil }
        return pod.images.first { image in
            local.contains { $0 == image || $0.hasSuffix("/" + image) || $0.hasSuffix("/library/" + image) }
        }
    }
}
