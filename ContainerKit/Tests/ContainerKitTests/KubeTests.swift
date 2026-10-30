import XCTest
@testable import ContainerKit

final class KubeTests: XCTestCase {
    /// A fresh kind cluster (1.35), as kubectl in its node reports it.
    func testDecodesAClusterSnapshot() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "kube-snapshot", withExtension: "json",
                                                  subdirectory: "Fixtures/1.6.1"))
        let snapshot = try KubeSnapshot.decode(Data(contentsOf: url))
        XCTAssertEqual(snapshot.namespaces, ["default", "kube-node-lease", "kube-public", "kube-system"])
        let coredns = try XCTUnwrap(snapshot.workloads.first { $0.name == "coredns" })
        XCTAssertEqual(coredns.kind, .deployment)
        XCTAssertEqual(coredns.desired, 2)
        XCTAssertEqual(coredns.ready, 2)
        XCTAssertEqual(coredns.pods.count, 2, "pods found through their ReplicaSet")
        XCTAssertTrue(coredns.pods.allSatisfy { $0.health == .ok })
        XCTAssertTrue(coredns.isSystem)
        XCTAssertEqual(coredns.references, [KubeReference(kind: .configMap, name: "coredns")])
        let proxy = try XCTUnwrap(snapshot.workloads.first { $0.name == "kube-proxy" })
        XCTAssertEqual(proxy.kind, .daemonSet)
        XCTAssertEqual(proxy.pods.count, 1)
        // Static control-plane pods belong to no workload.
        XCTAssertTrue(snapshot.loosePods.contains { $0.name == "etcd-dev" })
        let dns = try XCTUnwrap(snapshot.services.first { $0.name == "kube-dns" })
        XCTAssertEqual(dns.ports.map(\.port), [53, 53, 9153])
        XCTAssertTrue(coredns.pods.allSatisfy(dns.selects))
    }

    /// A failing pod says why; a NodePort service shows its node port.
    func testFailingPodAndNodePort() throws {
        let json = """
        {"items":[
         {"kind":"Deployment","metadata":{"name":"web","namespace":"shop"},
          "spec":{"replicas":3,"selector":{"matchLabels":{"app":"web"}},
                  "template":{"spec":{"containers":[{"name":"web","image":"shop/web:dev",
                    "envFrom":[{"secretRef":{"name":"web-env"}}]}],
                    "volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"uploads"}}]}}},
          "status":{"readyReplicas":1}},
         {"kind":"ReplicaSet","metadata":{"name":"web-5d","namespace":"shop",
          "ownerReferences":[{"kind":"Deployment","name":"web"}]}},
         {"kind":"Pod","metadata":{"name":"web-5d-a","namespace":"shop","labels":{"app":"web"},
          "ownerReferences":[{"kind":"ReplicaSet","name":"web-5d"}]},
          "spec":{"containers":[{"name":"web","image":"shop/web:dev"}]},
          "status":{"phase":"Pending","containerStatuses":[{"ready":false,"restartCount":0,
           "state":{"waiting":{"reason":"ErrImagePull","message":"pull access denied"}}}]}},
         {"kind":"Pod","metadata":{"name":"web-5d-b","namespace":"shop","labels":{"app":"web"},
          "ownerReferences":[{"kind":"ReplicaSet","name":"web-5d"}]},
          "spec":{"containers":[{"name":"web","image":"shop/web:dev"}]},
          "status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False",
           "reason":"Unschedulable","message":"0/1 nodes are available: insufficient memory"}]}},
         {"kind":"Service","metadata":{"name":"web","namespace":"shop"},
          "spec":{"type":"NodePort","selector":{"app":"web"},
                  "ports":[{"port":80,"targetPort":"http","nodePort":30080,"protocol":"TCP"}]}}
        ]}
        """
        let snapshot = try KubeSnapshot.decode(Data(json.utf8))
        let web = try XCTUnwrap(snapshot.workloads.first)
        XCTAssertEqual(web.desired, 3)
        XCTAssertEqual(web.ready, 1)
        XCTAssertEqual(web.images, ["shop/web:dev"])
        XCTAssertEqual(web.references.map(\.id), ["PVC/uploads", "Secret/web-env"])
        XCTAssertEqual(web.pods.map(\.reason), ["ErrImagePull", "Unschedulable"])
        XCTAssertEqual(web.pods[0].health, .failing)
        XCTAssertEqual(web.pods[1].health, .starting)
        XCTAssertEqual(web.pods[1].message, "0/1 nodes are available: insufficient memory")
        let service = try XCTUnwrap(snapshot.services.first)
        XCTAssertEqual(service.ports.first?.nodePort, 30080)
        XCTAssertEqual(service.ports.first?.target, "http")
        XCTAssertEqual(service.selector, ["app": "web"])
    }

    func testCommandsRunInTheNode() async throws {
        let cli = KubeRecorder()
        let client = KubeClient(cli: cli, node: "dev")
        let web = KubeWorkload(kind: .deployment, namespace: "shop", name: "web", desired: 2, ready: 2,
                               images: [], selector: [:], pods: [])
        try await client.scale(web, to: 3)
        try await client.restart(web)
        XCTAssertEqual(cli.calls, [
            ["exec", "dev", "kubectl", "scale", "deployment/web", "--namespace", "shop", "--replicas", "3"],
            ["exec", "dev", "kubectl", "rollout", "restart", "deployment/web", "--namespace", "shop"],
        ])
        let pod = KubePod(namespace: "shop", name: "web-1", phase: "Running", ready: true, restarts: 0,
                          reason: nil, message: nil, images: [], node: nil, labels: [:], containers: ["web"])
        XCTAssertEqual(Array(client.shellArguments(pod).prefix(5)), ["exec", "--interactive", "--tty", "dev", "kubectl"])
    }

    /// The real cluster `dev` if it runs: IREKOBOX_LIVE_KUBE=1 (read only).
    func testLiveSnapshot() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_KUBE"] == "1", "live only")
        let snapshot = try await KubeClient(cli: ContainerCLI(), node: "dev").snapshot()
        XCTAssertTrue(snapshot.namespaces.contains("kube-system"))
        print("workloads:", snapshot.workloads.map(\.id))
    }
}

private final class KubeRecorder: ContainerCommanding, @unchecked Sendable {
    var calls: [[String]] = []
    func data(_ arguments: [String]) async throws -> Data { calls.append(arguments); return Data("{}".utf8) }
    func decode<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String],
                                         alsoAccepting exitCodes: Set<Int32>) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(arguments))
    }
    func run(_ arguments: [String], workingDirectory: URL?) async throws { calls.append(arguments) }
    func run(_ arguments: [String], input: Data, workingDirectory: URL?) async throws { calls.append(arguments) }
}

final class KubeManifestTests: XCTestCase {
    func testDeploymentWithNodePort() {
        let deployment = KubeDeployment(name: "web", namespace: "shop", image: "nginx:alpine", replicas: 2, port: 80,
                                        exposure: .mac, nodePort: 30080,
                                        environment: [(key: "MODE", value: "prod"), (key: "WORKERS", value: "4")],
                                        createNamespace: true)
        XCTAssertEqual(deployment.yaml, """
        apiVersion: v1
        kind: Namespace
        metadata:
          name: shop
        ---
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
          namespace: shop
          labels:
            app: web
        spec:
          replicas: 2
          selector:
            matchLabels:
              app: web
          template:
            metadata:
              labels:
                app: web
            spec:
              containers:
              - name: web
                image: nginx:alpine
                imagePullPolicy: IfNotPresent
                ports:
                  - containerPort: 80
                env:
                  - name: MODE
                    value: prod
                  - name: WORKERS
                    value: "4"
        ---
        apiVersion: v1
        kind: Service
        metadata:
          name: web
          namespace: shop
        spec:
          type: NodePort
          selector:
            app: web
          ports:
            - port: 80
              targetPort: 80
              nodePort: 30080

        """)
    }

    func testTeachingForms() {
        let deployment = KubeDeployment(name: "web", image: "nginx:alpine", replicas: 2, port: 80, exposure: .mac)
        XCTAssertEqual(deployment.kubectlCommands, [
            "kubectl create deployment web --image=nginx:alpine --replicas=2 --port=80 -n default",
            "kubectl expose deployment web --port=80 --type=NodePort -n default",
        ])
        let annotated = deployment.annotatedYAML
        XCTAssertTrue(annotated.contains("# A Deployment keeps the pods below running"))
        XCTAssertTrue(annotated.contains("  # NodePort: also opens a port"))
        XCTAssertEqual(annotated.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n") + "\n", deployment.yaml.split(separator: "\n").joined(separator: "\n") + "\n",
            "comments only")
    }

    func testNoServiceWithoutAPort() {
        let yaml = KubeDeployment(name: "worker", image: "busybox", exposure: .cluster).yaml
        XCTAssertFalse(yaml.contains("kind: Service"))
        XCTAssertEqual(KubeDeployment.suggestedName(for: "ghcr.io/me/Web_App:1.2"), "web-app")
        XCTAssertTrue(KubeDeployment.isValidName("web-1"))
        XCTAssertFalse(KubeDeployment.isValidName("Web"))
    }

    /// The generated manifests are what the API server accepts:
    /// IREKOBOX_LIVE_KUBE=1 (server-side dry run in the dev cluster; nothing changes).
    func testServerAcceptsTheManifests() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_KUBE"] == "1", "live only")
        let yaml = KubeDeployment(name: "ib-dry-run", image: "nginx:alpine", replicas: 1, port: 80, exposure: .mac,
                                  environment: [(key: "A", value: "1")]).yaml
        try await KubeClient(cli: ContainerCLI(), node: "dev").check(yaml)
    }
}

final class KubePortCheckTests: XCTestCase {
    private let service = KubeService(namespace: "gateway", name: "nginx", type: "NodePort",
                                      ports: [.init(name: nil, port: 8080, target: "8080", nodePort: 32327, proto: "TCP")],
                                      selector: ["app": "nginx"])

    func testWrongTargetPortIsFound() {
        let nginx = [ContainerCheckup.Listener(address: "0.0.0.0", port: 80), .init(address: "::", port: 80)]
        let problems = KubePortCheck.problems(service, listeners: [nginx])
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.suggested, 80)
        XCTAssertEqual(problems.first?.message, "nginx sends to port 8080, but its pods listen on 80.")
        XCTAssertTrue(KubePortCheck.problems(service, listeners: [[.init(address: "0.0.0.0", port: 8080)]]).isEmpty)
        let loopback = KubePortCheck.problems(service, listeners: [[.init(address: "127.0.0.1", port: 8080)]])
        XCTAssertEqual(loopback.first?.loopbackOnly, true)
    }

    func testEditableYAMLDropsServerFields() {
        let yaml = """
        apiVersion: v1
        kind: Service
        metadata:
          annotations:
            kubectl.kubernetes.io/last-applied-configuration: |
              {"apiVersion":"v1"}
          creationTimestamp: "2026-10-27T01:40:00Z"
          name: nginx
          namespace: gateway
          resourceVersion: "1234"
          uid: 5f0
        spec:
          ports:
          - nodePort: 32327
            port: 8080
        status:
          loadBalancer: {}

        """
        XCTAssertEqual(KubeYAML.editable(yaml), """
        apiVersion: v1
        kind: Service
        metadata:
          name: nginx
          namespace: gateway
        spec:
          ports:
          - nodePort: 32327
            port: 8080

        """)
    }

    /// An nginx deployment in the dev cluster, read only: IREKOBOX_LIVE_KUBE=1.
    func testLiveNginx() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_KUBE"] == "1", "live only")
        let client = KubeClient(cli: ContainerCLI(), node: "dev")
        let snapshot = try await client.snapshot()
        guard let nginx = snapshot.services.first(where: { $0.name == "nginx" && $0.namespace == "gateway" }) else {
            throw XCTSkip("no nginx in gateway")
        }
        let pods = snapshot.workloads.flatMap(\.pods).filter(nginx.selects)
        var listeners: [[ContainerCheckup.Listener]] = []
        for pod in pods { listeners.append(try await client.listeners(pod)) }
        print("LISTENERS:", listeners)
        print("PROBLEMS:", KubePortCheck.problems(nginx, listeners: listeners).map(\.message))
        print("YAML:\n" + (try await client.editableYAML("service/nginx", namespace: "gateway")))
    }
}
