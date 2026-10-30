import Foundation

/// Turns a ``ParsedCompose`` into an ordered ``ComposePlan`` of `container`
/// invocations. Pure and deterministic — ideal for fixture-based tests.
public struct ComposePlanner: Sendable {
    public init() {}

    public func plan(
        _ parsed: ParsedCompose,
        projectName: String? = nil,
        activeProfiles: Set<String> = [],
        extraRunLabels: [String: String] = [:],
        localDomain: String? = nil
    ) throws -> ComposePlan {
        let file = parsed.file
        let project = sanitize(projectName ?? file.name ?? "compose")

        // 1. Select services by profile.
        let included = file.services.filter { _, service in
            guard let profiles = service.profiles, !profiles.isEmpty else { return true }
            return !Set(profiles).isDisjoint(with: activeProfiles)
        }

        var steps: [PlanStep] = []
        var warnings: [PlanWarning] = []

        // 2. Networks: a project default plus any explicit, non-external networks used.
        let defaultNetwork = "\(project)-default"
        var networksToCreate: [String] = []
        var usesDefault = false
        for (_, service) in included {
            if let names = service.networks?.names, !names.isEmpty {
                for key in names {
                    if isExternalNetwork(key, file: file) { continue }
                    let resolved = networkName(key, project: project, file: file)
                    if !networksToCreate.contains(resolved) { networksToCreate.append(resolved) }
                }
            } else {
                usesDefault = true
            }
        }
        if usesDefault { networksToCreate.insert(defaultNetwork, at: 0) }
        for net in networksToCreate {
            steps.append(PlanStep(kind: .network, arguments: ["network", "create", net]))
        }

        // 3. Named volumes (skip external).
        if let volumes = file.volumes {
            for key in volumes.keys.sorted() {
                if let def = volumes[key], let def, def.external == true { continue }
                steps.append(PlanStep(kind: .volume, arguments: ["volume", "create", volumeName(key, project: project, file: file)]))
            }
        }

        // 4. Order services by depends_on.
        let order = try topologicalOrder(included)

        // 5. Build + run each service.
        for name in order {
            guard let service = included[name] else { continue }
            let rawKeys = parsed.rawServiceKeys[name] ?? []
            warnings.append(contentsOf: classify(rawKeys, service: name))

            // Resolve the image (build → derived tag).
            let builtTag = "\(project)-\(name)"
            var runImage = service.image
            if let build = service.build {
                let tag = service.image ?? builtTag
                runImage = tag
                steps.append(buildStep(service: name, tag: tag, build: build))
            }
            guard let image = runImage else { throw ComposePlanError.missingImage(service: name) }

            let replicas = max(1, service.scale ?? 1)
            if replicas > 1, service.ports?.isEmpty == false {
                warnings.append(PlanWarning(service: name, field: "scale",
                    message: String(localized: "Scaled service publishes ports; host ports will collide across replicas."),
                    severity: .partial))
            }

            for index in 1...replicas {
                let containerName = replicas > 1
                    ? "\(service.containerName ?? "\(project)-\(name)")-\(index)"
                    : (service.containerName ?? "\(project)-\(name)")
                let (args, runWarnings) = runArguments(
                    service: service, serviceName: name, containerName: containerName,
                    image: image, project: project, defaultNetwork: defaultNetwork, file: file,
                    extraLabels: extraRunLabels, localDomain: localDomain
                )
                steps.append(PlanStep(kind: .run, service: name, containerName: containerName, arguments: args))
                warnings.append(contentsOf: runWarnings)
            }
        }

        return ComposePlan(projectName: project, steps: steps, warnings: warnings)
    }

    // MARK: - Run argv

    private func runArguments(
        service: Service, serviceName: String, containerName: String,
        image: String, project: String, defaultNetwork: String, file: ComposeFile,
        extraLabels: [String: String] = [:], localDomain: String? = nil
    ) -> ([String], [PlanWarning]) {
        var args = ["run", "--detach", "--name", containerName]
        var warnings: [PlanWarning] = []
        // What Docker Compose writes, so tools group the containers the same way.
        args += ["--label", "com.docker.compose.project=\(project)",
                 "--label", "com.docker.compose.service=\(serviceName)"]
        for key in extraLabels.keys.sorted() {
            args += ["--label", "\(key)=\(extraLabels[key]!)"]
        }

        // Networks. With a local DNS domain the first one carries the name
        // `<service>.<project>.<domain>`, reachable from the Mac.
        let dnsName = localDomain.flatMap { Self.dnsName(service: serviceName, project: project, domain: $0) }
        var networks: [String] = []
        if let names = service.networks?.names, !names.isEmpty {
            networks = names.map { networkName($0, project: project, file: file) }
        } else {
            networks = [defaultNetwork]
        }
        for (index, network) in networks.enumerated() {
            args += ["--network", index == 0 && dnsName != nil ? "\(network),alias=\(dnsName!)" : network]
        }

        // Environment
        for pair in service.environment?.pairs ?? [] {
            args += ["--env", pair.value.map { "\(pair.key)=\($0)" } ?? pair.key]
        }
        for file in service.envFile?.values ?? [] {
            args += ["--env-file", file]
        }

        if let workingDir = service.workingDir { args += ["--workdir", workingDir] }
        if let user = service.user { args += ["--user", user] }

        // Ports
        for port in service.ports ?? [] {
            guard port.target != nil else {
                warnings.append(PlanWarning(service: serviceName, field: "ports",
                    message: String(localized: "Unsupported port spec `\(port.raw ?? "")` (e.g. a range); skipped."), severity: .partial))
                continue
            }
            guard port.published != nil else {
                warnings.append(PlanWarning(service: serviceName, field: "ports",
                    message: String(localized: "Port `\(port.shortSyntax)` has no host mapping; `container` needs a host port; skipped."),
                    severity: .partial))
                continue
            }
            args += ["--publish", port.shortSyntax]
        }

        // Volumes
        for mount in service.volumes ?? [] {
            switch mount.kind {
            case .bind:
                args += ["--volume", mount.shortSyntax]
            case .volume:
                let name = mount.source.map { volumeName($0, project: project, file: file) } ?? ""
                args += ["--volume", "\(name):\(mount.target)\(mount.readOnly ? ":ro" : "")"]
            case .anonymous:
                args += ["--mount", "type=volume,target=\(mount.target)\(mount.readOnly ? ",readonly" : "")"]
            case .tmpfs:
                args += ["--tmpfs", mount.target]
            }
        }

        if let mem = service.memLimit { args += ["--memory", normalizeMemory(mem)] }
        if let cpus = service.cpus?.stringValue {
            args += ["--cpus", cpus]
            if cpus.contains(".") {
                warnings.append(PlanWarning(service: serviceName, field: "cpus",
                    message: String(localized: "Fractional cpus `\(cpus)` may be rounded by `container`."), severity: .partial))
            }
        }

        for cap in service.capAdd ?? [] { args += ["--cap-add", cap] }
        for cap in service.capDrop ?? [] { args += ["--cap-drop", cap] }
        for dns in service.dns?.values ?? [] { args += ["--dns", dns] }
        for label in service.labels?.pairs ?? [] {
            args += ["--label", label.value.map { "\(label.key)=\($0)" } ?? label.key]
        }
        // The background agent's supervisor reads this label (same key the
        // Docker API writes for `--restart`).
        if let restart = service.restart?.trimmingCharacters(in: .whitespaces), !restart.isEmpty, restart != "no" {
            args += ["--label", "com.irekobox.docker.restart=\(restart)"]
        }
        // Run by the agent's health monitor (same label as the Docker API).
        if let health = service.healthcheck?.dockerJSON {
            args += ["--label", "com.irekobox.docker.healthcheck=\(health)"]
        }

        if service.readOnly == true { args.append("--read-only") }
        if service.useInit == true { args.append("--init") }
        if service.tty == true { args.append("--tty") }
        if service.stdinOpen == true { args.append("--interactive") }
        if let platform = service.platform { args += ["--platform", platform] }
        if let shm = service.shmSize { args += ["--shm-size", normalizeMemory(shm)] }

        // Entrypoint (string form is shell-tokenized)
        let entrypointWords = service.entrypoint?.shellWords ?? []
        if let first = entrypointWords.first {
            args += ["--entrypoint", first]
            if entrypointWords.count > 1 {
                warnings.append(PlanWarning(service: serviceName, field: "entrypoint",
                    message: String(localized: "`container --entrypoint` takes one value; extra args appended to the command."),
                    severity: .partial))
            }
        }

        // Image (positional) + command (trailing). String command is shell-split.
        args.append(image)
        args += Array(entrypointWords.dropFirst())
        args += service.command?.shellWords ?? []

        return (args, warnings)
    }

    private func buildStep(service: String, tag: String, build: BuildSpec) -> PlanStep {
        var args = ["build", "--tag", tag]
        if let dockerfile = build.dockerfile { args += ["--file", dockerfile] }
        for arg in build.args?.pairs ?? [] {
            args += ["--build-arg", arg.value.map { "\(arg.key)=\($0)" } ?? arg.key]
        }
        args.append(build.context ?? ".")
        return PlanStep(kind: .build, service: service, arguments: args)
    }

    // MARK: - Topological sort (Kahn, deterministic)

    private func topologicalOrder(_ services: [String: Service]) throws -> [String] {
        let names = Set(services.keys)
        var dependents: [String: [String]] = [:]   // dep → [services depending on dep]
        var indegree: [String: Int] = [:]
        for name in names { indegree[name] = 0 }

        for (name, service) in services {
            for dep in service.dependsOn?.dependencies ?? [] {
                guard names.contains(dep.service) else {
                    throw ComposePlanError.unknownDependency(service: name, dependency: dep.service)
                }
                dependents[dep.service, default: []].append(name)
                indegree[name, default: 0] += 1
            }
        }

        var ready = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var order: [String] = []
        while !ready.isEmpty {
            let node = ready.removeFirst()
            order.append(node)
            for next in (dependents[node] ?? []).sorted() {
                indegree[next]! -= 1
                if indegree[next]! == 0 {
                    ready.append(next)
                    ready.sort()
                }
            }
        }

        guard order.count == names.count else {
            throw ComposePlanError.dependencyCycle(names.subtracting(order).sorted())
        }
        return order
    }

    // MARK: - Warnings classification

    private static let supported: Set<String> = [
        "image", "build", "command", "entrypoint", "environment", "env_file",
        "working_dir", "user", "ports", "volumes", "networks", "labels",
        "cpus", "mem_limit", "cap_add", "cap_drop", "dns", "container_name",
        "read_only", "init", "tty", "stdin_open", "platform", "shm_size",
    ]
    private static let appLevel: [String: String] = [
        "depends_on": String(localized: "ordering handled by the planner"),
        "restart": String(localized: "restart policy applied by the background helper's supervisor"),
        "healthcheck": String(localized: "run by the background helper; unhealthy containers are reported"),
        "profiles": String(localized: "selects which services start"),
        "scale": String(localized: "launches N containers"),
        "deploy": String(localized: "only `resources.limits` honored; placement/replicas partial"),
    ]
    private static let partial: [String: String] = [
        "hostname": String(localized: "no `--hostname`; defaults to the container name"),
        "domainname": String(localized: "no analog", comment: "Note on a compose key that has no equivalent"),
        "network_mode": String(localized: "only user-defined networks; host/container/service unsupported"),
        "expose": String(localized: "informational; intra-network reachability is implicit"),
        "sysctls": String(localized: "no `run` flag"),
    ]

    private func classify(_ keys: Set<String>, service: String) -> [PlanWarning] {
        var result: [PlanWarning] = []
        for key in keys.sorted() {
            if Self.supported.contains(key) { continue }
            if let note = Self.appLevel[key] {
                result.append(PlanWarning(service: service, field: key, message: note, severity: .info))
            } else if let note = Self.partial[key] {
                result.append(PlanWarning(service: service, field: key, message: note, severity: .partial))
            } else {
                result.append(PlanWarning(service: service, field: key,
                    message: String(localized: "No analog in `container`'s per-VM model; ignored."), severity: .unsupported))
            }
        }
        return result
    }

    // MARK: - Naming helpers

    private func sanitize(_ name: String) -> String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed)
    }

    private func networkName(_ key: String, project: String, file: ComposeFile) -> String {
        if let def = file.networks?[key], let def, let explicit = def.name { return explicit }
        return "\(project)-\(key)"
    }

    private func volumeName(_ key: String, project: String, file: ComposeFile) -> String {
        if let def = file.volumes?[key], let def, let explicit = def.name { return explicit }
        return "\(project)-\(key)"
    }

    private func isExternalNetwork(_ key: String, file: ComposeFile) -> Bool {
        if let def = file.networks?[key], let def { return def.external == true }
        return false
    }

    /// `512m`/`1gb` → `512M`/`1G` for `container --memory`.
    private func normalizeMemory(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasSuffix("b") { s.removeLast() }
        guard let last = s.last, last.isLetter else { return s }
        return s.dropLast() + String(last).uppercased()
    }

    /// `web.shop.test`: lowercase letters, digits and hyphens per label.
    static func dnsName(service: String, project: String, domain: String) -> String? {
        func label(_ text: String) -> String {
            String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let service = label(service), project = label(project)
        guard !service.isEmpty, !project.isEmpty, !domain.isEmpty else { return nil }
        return "\(service).\(project).\(domain)"
    }
}
