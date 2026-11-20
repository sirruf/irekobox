import Foundation
import Darwin
import ContainerKit

/// Host port ranges in a create request (`"8080-8081:80"`, or a long-syntax
/// `published: 8080-8081`, which compose sends as `HostPort: "8080-8081"`).
/// Like Docker, each binding gets the first port of its range that is free:
/// not published by a container that is running or still waiting for its
/// first start, not being taken by a parallel create, and bindable here.
enum HostPortRanges {
    struct Resolved {
        /// Chosen port by `CreateMapping.rangeKey(port key, binding index)`.
        var ports: [String: Int] = [:]
        /// `CreateClaims` keys the caller releases once the container exists.
        var claims: [String] = []
    }

    /// `"8080-8081"` → 8080...8081; nil when it isn't a range.
    static func parse(_ text: String) throws -> ClosedRange<Int>? {
        guard text.contains("-") else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]),
              1 <= low, low <= high, high <= 65535 else {
            throw DockerAPIError.badParameter("invalid host port range: \(text)")
        }
        return low...high
    }

    static func resolve(_ request: CreateRequest, _ backend: DockerBackend,
                        isFree: (Int, String, String?) -> Bool = FreePort.isFree(_:_:_:)) async throws -> Resolved {
        let bindings = request.HostConfig?.PortBindings ?? [:]
        var wanted: [(key: String, index: Int, range: ClosedRange<Int>, proto: String, ip: String?)] = []
        for key in bindings.keys.sorted() {
            for (index, binding) in ((bindings[key] ?? nil) ?? []).enumerated() {
                guard let text = binding.HostPort, let range = try parse(text) else { continue }
                let proto = key.split(separator: "/").dropFirst().first.map { String($0).lowercased() } ?? "tcp"
                wanted.append((key, index, range, proto, binding.HostIp.flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        guard !wanted.isEmpty else { return Resolved() }

        let taken = try await publishedPorts(backend)
        var resolved = Resolved()
        do {
            for item in wanted {
                var chosen: Int?
                for port in item.range where !taken.contains(CreateClaims.portKey(port, proto: item.proto)) {
                    let claim = CreateClaims.portKey(port, proto: item.proto)
                    guard await CreateClaims.shared.claim(claim) else { continue }
                    if isFree(port, item.proto, item.ip) {
                        chosen = port
                        resolved.claims.append(claim)
                        break
                    }
                    await CreateClaims.shared.release([claim])
                }
                guard let chosen else {
                    let ip = item.ip ?? "0.0.0.0"
                    throw DockerAPIError(500, "Bind for \(ip):\(item.range.lowerBound)-\(item.range.upperBound) failed: port is already allocated")
                }
                resolved.ports[CreateMapping.rangeKey(item.key, item.index)] = chosen
            }
        } catch {
            await CreateClaims.shared.release(resolved.claims)
            throw error
        }
        return resolved
    }

    /// Ports held by containers that are up, or created and not yet started
    /// (compose creates every replica before starting any). A container that
    /// ran and stopped holds none, as in Docker.
    static func publishedPorts(_ backend: DockerBackend) async throws -> Set<String> {
        var keys: Set<String> = []
        for container in try await backend.listContainers(all: true) {
            let holds = container.state != .stopped || container.status.startedDate == nil
            guard holds else { continue }
            for published in container.configuration.publishedPorts ?? [] {
                let proto = published.proto ?? "tcp"
                for offset in 0..<max(1, published.count ?? 1) {
                    keys.insert(CreateClaims.portKey(published.hostPort + offset, proto: proto))
                }
            }
        }
        return keys
    }
}

extension FreePort {
    /// Whether `port` can be bound on this Mac (`host` address, or all).
    static func isFree(_ port: Int, proto: String, host: String?) -> Bool {
        let type = proto == "udp" ? SOCK_DGRAM : SOCK_STREAM
        if let host, host.contains(":") {
            let fd = socket(AF_INET6, type, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), &address.sin6_addr) == 1 else { return false }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0
        }
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        if let host, host != "0.0.0.0" {
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        } else {
            address.sin_addr.s_addr = INADDR_ANY
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    static func isFree(_ port: Int, _ proto: String, _ host: String?) -> Bool {
        isFree(port, proto: proto, host: host)
    }
}
