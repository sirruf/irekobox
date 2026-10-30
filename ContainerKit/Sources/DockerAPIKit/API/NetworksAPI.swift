import Foundation
import CryptoKit
import ContainerKit

/// Networks as Docker clients see them. `container`'s built-in `default`
/// network is Docker's `bridge`; `host` and `none` are listed (tools expect
/// them) but can't be used, since every container has its own VM.
public enum NetworksAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend) {
        let directory = NetworkDirectory(backend: backend)
        router.add("GET", "/networks") { request in
            await respond { try await list(request, directory) }
        }
        router.add("GET", "/networks/{id}") { request in
            await respond {
                let network = try await directory.resolve(request.parameters["id"]!)
                return .json(model(network, containers: try await backend.listContainers(all: true)))
            }
        }
        router.add("POST", "/networks/create") { request in
            await respond { try await create(request, directory, backend) }
        }
        router.add("DELETE", "/networks/{id}") { request in
            await respond { try await remove(request, directory, backend) }
        }
        router.add("POST", "/networks/{id}/connect") { request in
            await respond { try await connect(request, directory, backend, connecting: true) }
        }
        router.add("POST", "/networks/{id}/disconnect") { request in
            await respond { try await connect(request, directory, backend, connecting: false) }
        }
        router.add("POST", "/networks/prune") { request in
            await respond { try await prune(request, directory, backend) }
        }
    }

    // MARK: - Model

    struct Model: Encodable {
        struct IPAM: Encodable {
            struct Config: Encodable {
                let Subnet: String
                let Gateway: String?
            }
            let Driver = "default"
            let Options: [String: String]? = nil
            let Config: [Config]
        }
        struct Endpoint: Encodable {
            let Name: String
            let EndpointID: String
            let MacAddress: String
            let IPv4Address: String
            let IPv6Address: String
        }
        struct ConfigFrom: Encodable { let Network = "" }
        let Name: String
        let Id: String
        let Created: String
        let Scope = "local"
        let Driver: String
        let EnableIPv4: Bool
        let EnableIPv6: Bool
        let IPAM: IPAM
        let Internal: Bool
        let Attachable = false
        let Ingress = false
        let ConfigFrom = ConfigFrom()
        let ConfigOnly = false
        let Containers: [String: Endpoint]
        let Options: [String: String]
        let Labels: [String: String]
    }

    static func model(_ network: DockerNetwork, containers: [Container]) -> Model {
        guard let real = network.network else {
            // host / none: listed only.
            return Model(Name: network.name, Id: network.id, Created: DockerTime.zero, Driver: network.name == "host" ? "host" : "null",
                         EnableIPv4: false, EnableIPv6: false, IPAM: .init(Config: []), Internal: false,
                         Containers: [:], Options: [:], Labels: [:])
        }
        var endpoints: [String: Model.Endpoint] = [:]
        for container in containers {
            guard let attachment = container.status.networks.first(where: { $0.network == real.name }) else { continue }
            let id = DockerContainer.id(for: container)
            endpoints[id] = Model.Endpoint(Name: container.id, EndpointID: "\(container.id)-\(real.name)",
                                           MacAddress: attachment.macAddress ?? "",
                                           IPv4Address: attachment.ipv4Address ?? "", IPv6Address: attachment.ipv6Address ?? "")
        }
        var configs: [Model.IPAM.Config] = []
        if let subnet = real.status?.ipv4Subnet {
            configs.append(.init(Subnet: subnet, Gateway: real.status?.ipv4Gateway))
        }
        if let subnet = real.status?.ipv6Subnet { configs.append(.init(Subnet: subnet, Gateway: nil)) }
        let created = real.configuration.creationDate.flatMap(DockerTime.parse)
        return Model(Name: network.name, Id: network.id, Created: DockerTime.string(created), Driver: "bridge",
                     EnableIPv4: true, EnableIPv6: real.status?.ipv6Subnet != nil, IPAM: .init(Config: configs),
                     Internal: real.mode == "hostOnly", Containers: endpoints,
                     Options: real.configuration.options ?? [:], Labels: userLabels(real))
    }

    /// Labels without `container`'s own bookkeeping.
    static func userLabels(_ network: Network) -> [String: String] {
        (network.configuration.labels ?? [:]).filter { !$0.key.hasPrefix("com.apple.container.") }
    }

    // MARK: - List

    static func list(_ request: DockerRequest, _ directory: NetworkDirectory) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["name", "id", "label", "driver", "type", "scope", "dangling"])
        let containers = try await directory.backend.listContainers(all: true)
        let networks = try await directory.all().filter { network in
            if !filters["name"].isEmpty, !filters["name"].contains(where: { network.name.contains($0) }) { return false }
            if !filters["id"].isEmpty, !filters["id"].contains(where: { network.id.hasPrefix($0) }) { return false }
            let driver = network.network == nil ? (network.name == "host" ? "host" : "null") : "bridge"
            if !filters["driver"].isEmpty, !filters["driver"].contains(driver) { return false }
            if let type = filters["type"].first {
                if (type == "builtin") != network.isBuiltin { return false }
            }
            if !filters["scope"].isEmpty, !filters["scope"].contains("local") { return false }
            if let dangling = filters["dangling"].first {
                let unused = !network.isBuiltin && users(of: network, in: containers).isEmpty
                if unused != (dangling == "true" || dangling == "1") { return false }
            }
            return filters.matchesLabels(network.network.map(userLabels) ?? [:])
        }
        return .json(networks.map { model($0, containers: containers) })
    }

    static func users(of network: DockerNetwork, in containers: [Container]) -> [Container] {
        guard let name = network.network?.name else { return [] }
        return containers.filter { container in container.configuration.networks.contains { $0.network == name } }
    }

    // MARK: - Create / remove / prune

    struct CreateRequest: Decodable {
        struct IPAM: Decodable {
            struct Config: Decodable {
                let Subnet: String?
                let Gateway: String?
                let IPRange: String?
            }
            let Driver: String?
            let Config: [Config]?
        }
        let Name: String
        let Driver: String?
        let Internal: Bool?
        let EnableIPv6: Bool?
        let IPAM: IPAM?
        let Options: [String: String]?
        let Labels: [String: String]?
    }

    struct CreateResponse: Encodable {
        let Id: String
        let Warning: String
    }

    static func create(_ request: DockerRequest, _ directory: NetworkDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        guard let spec = try? JSONDecoder().decode(CreateRequest.self, from: request.http.body) else {
            throw DockerAPIError.badParameter("invalid JSON body (Name is required)")
        }
        guard !spec.Name.isEmpty else { throw DockerAPIError.badParameter("network name is required") }
        if let driver = spec.Driver, !driver.isEmpty, driver != "bridge" {
            throw DockerAPIError.badParameter("network driver \"\(driver)\" is not supported: only bridge networks exist")
        }
        if NetworkDirectory.predefined.contains(spec.Name) || spec.Name == "default" {
            throw DockerAPIError(403, "operation is not permitted on predefined \(spec.Name) network")
        }
        if try await directory.all().contains(where: { $0.name == spec.Name }) {
            throw DockerAPIError(409, "network with name \(spec.Name) already exists")
        }
        var network = NetworkSpec(name: spec.Name)
        var warnings: [String] = []
        for config in spec.IPAM?.Config ?? [] {
            guard let subnet = config.Subnet, !subnet.isEmpty else { continue }
            if subnet.contains(":") { network.subnetV6 = subnet } else { network.subnet = subnet }
            if config.Gateway != nil || config.IPRange != nil {
                warnings.append("Gateway and IPRange are chosen by the runtime and were ignored")
            }
        }
        network.hostOnly = spec.Internal ?? false
        network.labels = spec.Labels ?? [:]
        if !(spec.Options ?? [:]).isEmpty { warnings.append("driver options were ignored") }
        try await ContainersAPI.engine { try await backend.createNetwork(network) }
        let created = try await directory.resolve(spec.Name)
        return .json(CreateResponse(Id: created.id, Warning: Array(Set(warnings)).sorted().joined(separator: "; ")), status: 201)
    }

    static func remove(_ request: DockerRequest, _ directory: NetworkDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let network = try await directory.resolve(request.parameters["id"]!)
        guard let real = network.network, !network.isBuiltin else {
            throw DockerAPIError(403, "\(network.name) is a pre-defined network and cannot be removed")
        }
        let users = users(of: network, in: try await backend.listContainers(all: true))
        if !users.isEmpty {
            throw DockerAPIError(409, "error while removing network: network \(network.name) id \(network.id) has active endpoints (\(users.map(\.id).joined(separator: ", ")))")
        }
        try await ContainersAPI.engine { try await backend.deleteNetwork(real.name) }
        return HTTPResponse(status: 204)
    }

    struct PruneReport: Encodable { let NetworksDeleted: [String]? }

    static func prune(_ request: DockerRequest, _ directory: NetworkDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["label", "label!", "until"])
        let until = try filters["until"].first.map { text -> Date in
            guard let date = DockerTime.moment(text) else { throw DockerAPIError.badParameter("invalid until: \(text)") }
            return date
        }
        let containers = try await backend.listContainers(all: true)
        var deleted: [String] = []
        for network in try await directory.all() {
            guard let real = network.network, !network.isBuiltin, users(of: network, in: containers).isEmpty else { continue }
            let labels = userLabels(real)
            guard filters.matchesLabels(labels),
                  !filters["label!"].contains(where: { VolumesAPI.labelMatches($0, labels) }) else { continue }
            if let until, let created = real.configuration.creationDate.flatMap(DockerTime.parse), created > until { continue }
            if (try? await backend.deleteNetwork(real.name)) != nil { deleted.append(network.name) }
        }
        return .json(PruneReport(NetworksDeleted: deleted.isEmpty ? nil : deleted))
    }

    // MARK: - Connect / disconnect

    struct ConnectRequest: Decodable { let Container: String }

    /// Networks are fixed when a container is made. A request that changes
    /// nothing succeeds (compose connects the networks it already passed at
    /// create); anything else is refused with what to do instead.
    static func connect(_ request: DockerRequest, _ directory: NetworkDirectory, _ backend: DockerBackend,
                        connecting: Bool) async throws -> HTTPResponse {
        let network = try await directory.resolve(request.parameters["id"]!)
        guard let body = try? JSONDecoder().decode(ConnectRequest.self, from: request.http.body) else {
            throw DockerAPIError.badParameter("invalid JSON body (Container is required)")
        }
        let item = try await ContainerDirectory(backend: backend).resolve(body.Container)
        let attached = users(of: network, in: [item.container]).count == 1
        if attached == connecting { return HTTPResponse(status: 200) }
        if !connecting, network.network == nil { return HTTPResponse(status: 200) }
        throw DockerAPIError(409, "\(connecting ? "connecting" : "disconnecting") \(item.name) \(connecting ? "to" : "from") \(network.name) needs a new container: Irekobox fixes a container's networks when it is created (docker run --network \(network.name), or compose networks:)")
    }
}

/// A network under its Docker name and ID; `network` is nil for the listed-
/// only `host` and `none`.
struct DockerNetwork: Sendable {
    let name: String
    let id: String
    let network: Network?

    var isBuiltin: Bool { network == nil || network?.isBuiltin == true }
}

struct NetworkDirectory: Sendable {
    let backend: DockerBackend
    static let predefined: Set<String> = ["bridge", "host", "none"]

    static func id(_ name: String) -> String {
        SHA256.hash(data: Data("network\u{0}\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func all() async throws -> [DockerNetwork] {
        var result: [DockerNetwork] = []
        for network in try await backend.listNetworks() {
            let name = network.isBuiltin && network.name == "default" ? "bridge" : network.name
            result.append(DockerNetwork(name: name, id: Self.id(network.name), network: network))
        }
        for name in ["host", "none"] {
            result.append(DockerNetwork(name: name, id: Self.id(name), network: nil))
        }
        return result
    }

    /// By name (`default` too), full ID or unique ID prefix.
    func resolve(_ reference: String) async throws -> DockerNetwork {
        let networks = try await all()
        if let match = networks.first(where: { $0.name == reference || $0.network?.name == reference || $0.id == reference }) {
            return match
        }
        let prefixed = networks.filter { $0.id.hasPrefix(reference.lowercased()) }
        if prefixed.count > 1 { throw DockerAPIError(400, "network \(reference) is ambiguous (\(prefixed.count) matches found based on ID prefix)") }
        if let match = prefixed.first, !reference.isEmpty { return match }
        throw DockerAPIError(404, "network \(reference) not found")
    }
}
