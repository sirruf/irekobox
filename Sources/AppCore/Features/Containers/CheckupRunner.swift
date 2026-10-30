import Foundation
import Darwin
import ContainerKit

/// Gathers the facts ``ContainerCheckup`` decides on, for one running
/// container: its ports (from this Mac and from inside), the memory its VM
/// holds, and the folders it shares from the Mac.
enum CheckupRunner {
    static func run(_ container: Container, engine: any ContainerEngine) async -> [ContainerCheckup.Finding] {
        async let ports = portFindings(container, engine: engine)
        async let memory = memoryFinding(container, engine: engine)
        async let mounts = mountFindings(container)
        let all = await ports + [await memory].compactMap { $0 } + (await mounts)
        return all.sorted { $0.level > $1.level }
    }

    // MARK: - Ports

    static func portFindings(_ container: Container, engine: any ContainerEngine) async -> [ContainerCheckup.Finding] {
        let ports = (container.configuration.publishedPorts ?? []).filter { ($0.proto ?? "tcp").lowercased() == "tcp" }
        guard !ports.isEmpty else { return [] }
        // Read once: what listens inside (the image needs `cat`).
        let inside: [ContainerCheckup.Listener]? = await {
            guard let data = try? await engine.execute(container.id, command: ["cat", "/proc/net/tcp", "/proc/net/tcp6"]) else {
                return nil
            }
            return ContainerCheckup.listeners(procNet: String(decoding: data, as: UTF8.self))
        }()
        let address = container.status.networks.first?.ipv4Address?.split(separator: "/").first.map(String.init)
        var findings: [ContainerCheckup.Finding] = []
        for port in ports {
            let host = await reach("127.0.0.1", port.hostPort)
            var owner: String?
            var own = true
            var direct: ContainerCheckup.Reach?
            if host != .open {
                (owner, own) = await hostOwner(port.hostPort, container: container.id)
                if let address { direct = await reach(address, port.containerPort) }
            }
            findings.append(ContainerCheckup.port(host: port.hostPort, container: port.containerPort, reach: host,
                                                  hostOwner: owner, ownForwarder: own, inside: inside, direct: direct))
        }
        return findings
    }

    /// TCP connect with a timeout.
    static func reach(_ host: String, _ port: Int, timeout: Double = 1.5) async -> ContainerCheckup.Reach {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: connectProbe(host, port, timeout: timeout))
            }
        }
    }

    static func connectProbe(_ host: String, _ port: Int, timeout: Double) -> ContainerCheckup.Reach {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .refused }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .unreachable }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return errnoReach(errno) }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return .timedOut }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { return errnoReach(error) }
        }
        // A port forward accepts even when nothing listens behind it, and
        // then closes: wait a moment for that (a real server just waits).
        var reader = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&reader, 1, 500) > 0 else { return .open }
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK)
        return peeked > 0 ? .open : .dropped
    }

    static func errnoReach(_ code: Int32) -> ContainerCheckup.Reach {
        switch code {
        case ECONNREFUSED: return .refused
        case EHOSTUNREACH, ENETUNREACH, EPERM, EACCES: return .unreachable
        case ETIMEDOUT: return .timedOut
        default: return .refused
        }
    }

    /// Who listens on the host port, and whether it's this container's forwarder.
    static func hostOwner(_ port: Int, container: String) async -> (String?, Bool) {
        guard let output = try? await ProcessRunner.run(executable: "/usr/sbin/lsof",
                                                          ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]) else {
            return (nil, true)
        }
        var pid: String?
        var command: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let pid else { return (nil, true) }
        let full = (try? await ProcessRunner.run(executable: "/bin/ps", ["-o", "command=", "-p", pid])) ?? ""
        let own = full.contains("/containers/\(container) ") || full.hasSuffix("/containers/\(container)")
            || full.contains("/containers/\(container)\n")
        let name = full.contains("Docker.app") ? "Docker Desktop" : (command ?? "process \(pid)")
        return (name, own)
    }

    // MARK: - Memory

    static func memoryFinding(_ container: Container, engine: any ContainerEngine) async -> ContainerCheckup.Finding? {
        guard let stats = try? await engine.containerStats(container.id),
              let pid = await virtualMachinePID(container.id) else { return nil }
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return ContainerCheckup.memory(footprint: Int64(usage.ri_phys_footprint), used: stats.memoryUsageBytes,
                                       limit: stats.memoryLimitBytes)
    }

    /// The Virtualization process running this container's VM: the one
    /// holding its boot log open.
    static func virtualMachinePID(_ container: String) async -> Int32? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let log = support.appending(path: "com.apple.container/containers/\(container)/vminitd.log").path
        guard let output = try? await ProcessRunner.run(executable: "/usr/sbin/lsof", ["-t", log]) else { return nil }
        for pid in output.split(separator: "\n").compactMap({ Int32($0) }) {
            let command = (try? await ProcessRunner.run(executable: "/bin/ps", ["-o", "comm=", "-p", String(pid)])) ?? ""
            if command.contains("Virtualization") { return pid }
        }
        return nil
    }

    // MARK: - Mounts

    static func mountFindings(_ container: Container) async -> [ContainerCheckup.Finding] {
        let binds = (container.configuration.mounts ?? []).filter { $0.volumeName == nil }
        var findings: [ContainerCheckup.Finding] = []
        for mount in binds {
            guard let source = mount.source else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let probe = await Task.detached { probeFolder(source, destination: mount.destination) }.value
            findings.append(ContainerCheckup.mount(probe))
        }
        return findings
    }

    static func probeFolder(_ source: String, destination: String, cap: Int = 20_000) -> ContainerCheckup.MountProbe {
        let top = (try? FileManager.default.contentsOfDirectory(atPath: source)) ?? []
        let heavy = ContainerCheckup.heavyFolderNames.filter(top.contains)
        var count = 0
        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil,
                                                        options: [.skipsPackageDescendants])
        while enumerator?.nextObject() != nil {
            count += 1
            if count >= cap { break }
        }
        return ContainerCheckup.MountProbe(source: source, destination: destination, heavyFolders: heavy,
                                           fileCount: count, countCapped: count >= cap)
    }
}
