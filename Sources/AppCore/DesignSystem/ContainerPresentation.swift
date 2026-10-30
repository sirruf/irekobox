import Foundation
import ContainerKit

/// How a container's state reads in the UI — one source for the table, the
/// inspector, the menu bar and the palette.
struct ContainerPresentation: Equatable {
    let tone: Tone
    /// "Running", "Stopped", …
    let label: String
    /// Ports published on the host, in publish order.
    let ports: [PortLink]

    init(_ container: Container) {
        tone = Tone(container.state)
        switch container.state {
        case .running: label = String(localized: "Running")
        case .stopping: label = String(localized: "Stopping")
        case .stopped: label = String(localized: "Stopped")
        case .unknown(let raw): label = raw.capitalized
        }
        ports = (container.configuration.publishedPorts ?? []).map(PortLink.init)
    }

    /// Names this Mac resolves to the container under a local DNS domain:
    /// `name.test` and service names like `web.shop.test` (names with a dot).
    static func localNames(_ container: Container) -> [String] {
        var names: [String] = []
        for network in container.configuration.networks {
            if let hostname = network.options?.hostname?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
               hostname.contains(".") { names.append(hostname) }
            names += (network.options?.aliases ?? []).filter { $0.contains(".") }
        }
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    /// "2h 14m" since start; `nil` when not running.
    static func uptime(_ container: Container, now: Date = Date()) -> String? {
        guard container.state.isRunning, let started = container.startedDate else { return nil }
        return Format.duration(now.timeIntervalSince(started))
    }
}

/// A published port as something to click.
struct PortLink: Equatable, Identifiable {
    let hostPort: Int
    let containerPort: Int
    let proto: String
    /// Host interface the port listens on; `nil` means all interfaces.
    let hostAddress: String?

    var id: String { "\(hostAddress ?? "*"):\(hostPort)/\(proto)" }

    init(_ port: Container.PublishedPort) {
        hostPort = port.hostPort
        containerPort = port.containerPort
        proto = (port.proto ?? "tcp").lowercased()
        let address = port.hostAddress
        hostAddress = (address == nil || address == "0.0.0.0" || address == "::") ? nil : address
    }

    /// ":3000" — or ":5353/udp" for non-TCP.
    var label: String { proto == "tcp" ? ":\(hostPort)" : ":\(hostPort)/\(proto)" }

    /// `http://localhost:3000` for TCP ports; UDP has nothing to open.
    var url: URL? {
        guard proto == "tcp" else { return nil }
        let host = hostAddress ?? "localhost"
        return URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(hostPort)")
    }

    /// "Host 3000 → container 80".
    var accessibilityDescription: String {
        String(localized: "Port \(String(hostPort)) to container port \(String(containerPort)), \(proto)")
    }
}

extension Tone {
    init(_ state: Container.State) {
        switch state {
        case .running: self = .positive
        case .stopping: self = .warning
        case .stopped: self = .neutral
        case .unknown: self = .inactive
        }
    }
}
