import Foundation
import ContainerKit

/// Docker shapes for containers (`GET /containers/json`, `/containers/{id}/json`),
/// built from our model. Keys are Docker's.
enum ContainerModels {

    /// `docker.io/library/nginx:alpine` → `nginx:alpine`; `docker.io/x/y` → `x/y`.
    static func familiar(_ reference: String) -> String {
        if reference.hasPrefix("docker.io/library/") { return String(reference.dropFirst("docker.io/library/".count)) }
        if reference.hasPrefix("docker.io/") { return String(reference.dropFirst("docker.io/".count)) }
        return reference
    }

    struct Port: Encodable {
        let IP: String?
        let PrivatePort: Int
        let PublicPort: Int?
        let `Type`: String
    }

    struct PortBinding: Encodable, Equatable {
        let HostIp: String
        let HostPort: String
    }

    struct EndpointSettings: Encodable {
        let IPAMConfig: [String: String]? = nil
        let Links: [String]? = nil
        let Aliases: [String]?
        let MacAddress: String
        let NetworkID: String
        let EndpointID: String
        let Gateway: String
        let IPAddress: String
        let IPPrefixLen: Int
        let IPv6Gateway: String
        let GlobalIPv6Address: String
        let GlobalIPv6PrefixLen: Int
        let DNSNames: [String]?
    }

    struct MountPoint: Encodable {
        let `Type`: String
        let Name: String?
        let Source: String
        let Destination: String
        let Driver: String?
        let Mode: String
        let RW: Bool
        let Propagation: String
    }

    struct Summary: Encodable {
        struct HostConfig: Encodable { let NetworkMode: String }
        struct NetworkSettings: Encodable { let Networks: [String: EndpointSettings] }
        let Id: String
        let Names: [String]
        let Image: String
        let ImageID: String
        let Command: String
        let Created: Int64
        let Ports: [Port]
        let Labels: [String: String]
        let State: String
        let Status: String
        let HostConfig: HostConfig
        let NetworkSettings: NetworkSettings
        let Mounts: [MountPoint]
    }

    // MARK: - Pieces shared by summary and inspect

    static func ports(_ container: Container) -> [Port] {
        (container.configuration.publishedPorts ?? []).flatMap { port in
            (0..<max(1, port.count ?? 1)).map { offset in
                Port(IP: port.hostAddress ?? "0.0.0.0", PrivatePort: port.containerPort + offset,
                     PublicPort: port.hostPort + offset, Type: (port.proto ?? "tcp").lowercased())
            }
        }
    }

    /// `"80/tcp": [{HostIp, HostPort}]`.
    static func portBindings(_ container: Container) -> [String: [PortBinding]] {
        var result: [String: [PortBinding]] = [:]
        for port in ports(container) {
            result["\(port.PrivatePort)/\(port.Type)", default: []]
                .append(PortBinding(HostIp: port.IP ?? "", HostPort: port.PublicPort.map(String.init) ?? ""))
        }
        return result
    }

    static func networks(_ container: Container) -> [String: EndpointSettings] {
        var result: [String: EndpointSettings] = [:]
        let runtime = Dictionary(container.status.networks.compactMap { network in
            network.network.map { ($0, network) }
        }, uniquingKeysWith: { first, _ in first })
        for configured in container.configuration.networks {
            let attachment = runtime[configured.network]
            let cidr = attachment?.ipv4Address?.split(separator: "/") ?? []
            let address = cidr.first.map(String.init) ?? ""
            let prefix = cidr.count > 1 ? Int(cidr[1]) ?? 0 : 0
            let v6 = attachment?.ipv6Address?.split(separator: "/") ?? []
            result[configured.network] = EndpointSettings(
                Aliases: [container.id],
                MacAddress: attachment?.macAddress ?? "",
                NetworkID: NetworkDirectory.id(configured.network),
                EndpointID: attachment == nil ? "" : "\(container.id)-\(configured.network)",
                Gateway: attachment?.ipv4Gateway?.split(separator: "/").first.map(String.init) ?? "",
                IPAddress: address,
                IPPrefixLen: prefix,
                IPv6Gateway: "",
                GlobalIPv6Address: v6.first.map(String.init) ?? "",
                GlobalIPv6PrefixLen: v6.count > 1 ? Int(v6[1]) ?? 0 : 0,
                DNSNames: [container.id])
        }
        return result
    }

    static func mounts(_ container: Container) -> [MountPoint] {
        (container.configuration.mounts ?? []).map { mount in
            if let volume = mount.volumeName {
                return MountPoint(Type: "volume", Name: volume, Source: "", Destination: mount.destination,
                                  Driver: "local", Mode: mount.isReadOnly ? "ro" : "", RW: !mount.isReadOnly,
                                  Propagation: "")
            }
            return MountPoint(Type: "bind", Name: nil, Source: mount.source ?? "", Destination: mount.destination,
                              Driver: nil, Mode: mount.isReadOnly ? "ro" : "", RW: !mount.isReadOnly,
                              Propagation: "rprivate")
        }
    }

    static func command(_ container: Container) -> String {
        let process = container.configuration.initProcess
        return ([process.executable] + process.arguments).joined(separator: " ")
    }

    static func networkMode(_ container: Container) -> String {
        container.configuration.networks.first?.network ?? "none"
    }

    static func summary(_ item: DockerContainer, now: Date = Date()) -> Summary {
        let container = item.container
        let created = DockerTime.parse(container.configuration.creationDate)
        return Summary(
            Id: item.id,
            Names: ["/\(DockerContainer.dockerName(for: container))"],
            Image: familiar(container.configuration.image.reference),
            ImageID: container.configuration.image.descriptor.digest,
            Command: command(container),
            Created: Int64(created?.timeIntervalSince1970 ?? 0),
            Ports: ports(container),
            Labels: container.configuration.labels,
            State: item.state.rawValue,
            Status: item.statusText(now: now),
            HostConfig: .init(NetworkMode: networkMode(container)),
            NetworkSettings: .init(Networks: networks(container)),
            Mounts: mounts(container))
    }

    // MARK: - Inspect

    struct Inspect: Encodable {
        struct State: Encodable {
            let Status: String
            let Running: Bool
            let Paused = false
            let Restarting = false
            let OOMKilled = false
            let Dead = false
            let Pid: Int
            let ExitCode: Int32
            let Error = ""
            let StartedAt: String
            let FinishedAt: String
            let Health: HealthState?
        }
        struct HealthState: Encodable {
            struct Entry: Encodable {
                let Start: String
                let End: String
                let ExitCode: Int
                let Output: String
            }
            let Status: String
            let FailingStreak: Int
            let Log: [Entry]

            init(_ health: HealthMonitor.Health) {
                Status = health.status.rawValue
                FailingStreak = health.failingStreak
                Log = health.log.map {
                    Entry(Start: DockerTime.string($0.start), End: DockerTime.string($0.end),
                          ExitCode: $0.exitCode, Output: $0.output)
                }
            }
        }
        struct RestartPolicyValue: Encodable {
            let Name: String
            let MaximumRetryCount: Int

            /// From our label: "on-failure:3" → on-failure, 3.
            init(label: String?) {
                let parts = (label ?? "no").split(separator: ":", maxSplits: 1)
                Name = parts.first.map(String.init) ?? "no"
                MaximumRetryCount = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            }
        }
        struct LogConfigValue: Encodable {
            let `Type` = "json-file"
            let Config: [String: String] = [:]
        }
        struct HostConfig: Encodable {
            let NetworkMode: String
            let PortBindings: [String: [PortBinding]]
            let RestartPolicy: RestartPolicyValue
            let AutoRemove = false
            let Binds: [String]
            let Memory: Int64
            let NanoCpus: Int64
            let ReadonlyRootfs: Bool
            let Privileged = false
            let PublishAllPorts = false
            let LogConfig = LogConfigValue()
        }
        struct Config: Encodable {
            let Hostname: String
            let Domainname = ""
            let User = ""
            let AttachStdin = false
            let AttachStdout = false
            let AttachStderr = false
            let ExposedPorts: [String: [String: String]]?
            let Tty: Bool
            let OpenStdin = false
            let StdinOnce = false
            let Env: [String]
            let Cmd: [String]
            let Image: String
            let Volumes: [String: [String: String]]?
            let WorkingDir: String
            let Entrypoint: [String]?
            let Labels: [String: String]
            /// The healthcheck the container was created with. Compose reads
            /// it (not State.Health) for `condition: service_healthy`.
            let Healthcheck: CreateRequest.HealthConfig?
        }
        struct NetworkSettings: Encodable {
            let Bridge = ""
            let SandboxID = ""
            let Ports: [String: [PortBinding]]
            let SandboxKey = ""
            let EndpointID: String
            let Gateway: String
            let IPAddress: String
            let IPPrefixLen: Int
            let MacAddress: String
            let Networks: [String: EndpointSettings]
        }
        struct GraphDriverValue: Encodable {
            let Name = "container"
            let Data: [String: String] = [:]
        }

        let Id: String
        let Created: String
        let Path: String
        let Args: [String]
        let State: State
        let Image: String
        let ResolvConfPath = ""
        let HostnamePath = ""
        let HostsPath = ""
        let LogPath = ""
        let Name: String
        let RestartCount: Int
        let Driver = "container"
        let Platform: String
        let MountLabel = ""
        let ProcessLabel = ""
        let AppArmorProfile = ""
        let ExecIDs: [String]? = nil
        let HostConfig: HostConfig
        let GraphDriver = GraphDriverValue()
        let Mounts: [MountPoint]
        let Config: Config
        let NetworkSettings: NetworkSettings
    }

    static func inspect(_ item: DockerContainer, restartCount: Int = 0) -> Inspect {
        let container = item.container
        let configuration = container.configuration
        let process = configuration.initProcess
        let networks = networks(container)
        let primary = networks[networkMode(container)]
        let bindings = portBindings(container)
        let binds = (configuration.mounts ?? []).compactMap(\.runSpec)
        return Inspect(
            Id: item.id,
            Created: DockerTime.string(DockerTime.parse(configuration.creationDate)),
            Path: process.executable,
            Args: process.arguments,
            State: .init(Status: item.state.rawValue,
                         Running: item.state == .running,
                         Pid: 0,
                         ExitCode: item.exit?.code ?? 0,
                         StartedAt: DockerTime.string(container.startedDate),
                         FinishedAt: DockerTime.string(item.exit?.exitedAt),
                         Health: item.health.map(Inspect.HealthState.init)),
            Image: configuration.image.descriptor.digest,
            Name: "/\(DockerContainer.dockerName(for: container))",
            RestartCount: restartCount,
            Platform: configuration.platform.os,
            HostConfig: .init(NetworkMode: networkMode(container),
                              PortBindings: bindings,
                              RestartPolicy: .init(label: configuration.labels[DockerLabels.restartPolicy]),
                              Binds: binds,
                              Memory: configuration.resources.memoryInBytes,
                              NanoCpus: Int64(configuration.resources.cpus) * 1_000_000_000,
                              ReadonlyRootfs: configuration.readOnly),
            Mounts: mounts(container),
            Config: .init(Hostname: container.id,
                          ExposedPorts: bindings.isEmpty ? nil : bindings.mapValues { _ in [:] },
                          Tty: process.terminal ?? false,
                          Env: process.environment,
                          Cmd: [process.executable] + process.arguments,
                          Image: familiar(configuration.image.reference),
                          Volumes: nil,
                          WorkingDir: process.workingDirectory,
                          Entrypoint: nil,
                          Labels: configuration.labels,
                          Healthcheck: configuration.labels[DockerLabels.healthcheck]
                              .flatMap { try? JSONDecoder().decode(CreateRequest.HealthConfig.self, from: Data($0.utf8)) }),
            NetworkSettings: .init(Ports: bindings,
                                   EndpointID: primary?.EndpointID ?? "",
                                   Gateway: primary?.Gateway ?? "",
                                   IPAddress: primary?.IPAddress ?? "",
                                   IPPrefixLen: primary?.IPPrefixLen ?? 0,
                                   MacAddress: primary?.MacAddress ?? "",
                                   Networks: networks))
    }
}
