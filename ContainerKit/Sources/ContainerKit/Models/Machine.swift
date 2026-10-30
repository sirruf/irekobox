import Foundation

/// A container machine (`container machine inspect`, 1.6.1): a long-lived
/// Linux VM with the user's account and home folder, for a shell rather
/// than a service.
public struct Machine: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let cpus: Int
    /// Bytes.
    public let memory: Int64
    /// Bytes used by its disk.
    public let diskSize: Int64?
    public let ipAddress: String?
    public let createdDate: String?
    public let startedDate: String?
    /// Only in `list`; `inspect` leaves it out.
    public let `default`: Bool?
    public let homeMount: String?
    public let image: Image?
    public let platform: Platform?
    public let userSetup: User?
    /// The container that runs it.
    public let containerId: String?

    public struct Image: Codable, Hashable, Sendable {
        public let reference: String
    }

    public struct Platform: Codable, Hashable, Sendable {
        public let architecture: String?
        public let os: String?
    }

    public struct User: Codable, Hashable, Sendable {
        public let username: String?
        public let uid: Int?
        public let gid: Int?
        public let home: String?
    }

    public var isRunning: Bool { status == "running" }

    /// Whether `machine list` reports the same for `other` as for this one
    /// (`inspect` adds the rest, which only changes with these).
    func sameRow(as other: Machine) -> Bool {
        status == other.status && cpus == other.cpus && memory == other.memory && diskSize == other.diskSize
            && ipAddress == other.ipAddress && createdDate == other.createdDate && `default` == other.default
    }

    /// `alpine:latest` from `docker.io/library/alpine:latest`.
    public var imageShortName: String? {
        image.map { $0.reference.split(separator: "/").last.map(String.init) ?? $0.reference }
    }

    /// Settings `container machine set` takes (applied at the next start).
    public enum Setting: Sendable, Equatable {
        case cpus(Int)
        case memory(String)          // "8G"
        case homeMount(String)       // "rw", "ro", "none"
        case virtualization(Bool)

        var argument: String {
            switch self {
            case .cpus(let value): return "cpus=\(value)"
            case .memory(let value): return "memory=\(value)"
            case .homeMount(let value): return "home-mount=\(value)"
            case .virtualization(let value): return "virtualization=\(value)"
            }
        }
    }
}

/// `container machine …`.
public struct MachineRepository: Sendable {
    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    /// Every machine with its details (`list` for which is default, then
    /// `inspect` for the rest). A machine in `known` whose `list` row hasn't
    /// changed keeps its details without an `inspect`.
    public func list(known: [Machine] = []) async throws -> [Machine] {
        let listed = try await cli.decode([Machine].self, ["machine", "list", "--format", "json"])
        guard !listed.isEmpty else { return [] }
        let kept = listed.compactMap { row in known.first { $0.id == row.id && $0.sameRow(as: row) } }
        // `inspect` takes one name at a time.
        let cli = self.cli
        let detailed = await withTaskGroup(of: Machine?.self) { group in
            for row in listed where !kept.contains(where: { $0.id == row.id }) {
                group.addTask { try? await cli.decode([Machine].self, ["machine", "inspect", row.id]).first }
            }
            var result: [Machine] = []
            for await machine in group { if let machine { result.append(machine) } }
            return result
        }
        return listed.map { row in
            if let machine = kept.first(where: { $0.id == row.id }) { return machine }
            guard let detail = detailed.first(where: { $0.id == row.id }) else { return row }
            return Machine(id: row.id, status: row.status, cpus: row.cpus, memory: row.memory, diskSize: row.diskSize,
                           ipAddress: row.ipAddress, createdDate: row.createdDate, startedDate: detail.startedDate,
                           default: row.default, homeMount: detail.homeMount, image: detail.image,
                           platform: detail.platform, userSetup: detail.userSetup, containerId: detail.containerId)
        }
    }

    /// A valid machine name: lowercase letters, digits and hyphens, starting
    /// and ending with a letter or digit.
    public static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z0-9]([a-z0-9-]*[a-z0-9])?/) != nil
    }

    /// A name from the image (`ubuntu:24.04` → `ubuntu-24-04`, `alpine:latest`
    /// → `alpine`), unique among `taken`. `container` derives one itself but
    /// keeps the dots, which it then refuses.
    public static func suggestedName(for image: String, taken: Set<String> = []) -> String {
        var reference = image.split(separator: "@").first.map(String.init) ?? image
        if reference.hasSuffix(":latest") { reference.removeLast(":latest".count) }
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        var name = last.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? String($0) : "-" }.joined()
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "machine" }
        guard taken.contains(name) else { return name }
        return (2...).lazy.map { "\(name)-\($0)" }.first { !taken.contains($0) }!
    }

    /// Create and boot a machine; with no `name` the CLI picks one.
    public func create(image: String, name: String?, user: String? = nil) async throws {
        var arguments = ["machine", "create", "--progress", "none"]
        if let name, !name.isEmpty { arguments += ["--name", name] }
        if let user, !user.isEmpty { arguments += ["--user", user] }
        try await cli.run(arguments + [image])
    }

    /// Create without booting, with the given settings (for a rename).
    public func createStopped(image: String, name: String, cpus: Int, memoryBytes: Int64, homeMount: String?) async throws {
        var arguments = ["machine", "create", "--progress", "none", "--no-boot", "--name", name,
                         "--cpus", String(cpus), "--memory", "\(max(1, memoryBytes >> 20))M"]
        if let homeMount { arguments += ["--home-mount", homeMount] }
        try await cli.run(arguments + [image])
    }

    /// Where container keeps machines' disks (its machine plugin's state).
    public static var machinesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.container/plugin-state/machine-apiserver/machines")
    }

    /// A machine's disk image, as its rootfs.json names it.
    public static func disk(of name: String, in folder: URL = machinesFolder) -> URL? {
        let rootfs = folder.appending(path: "\(name)/rootfs.json")
        guard let data = try? Data(contentsOf: rootfs),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["source"] as? String,
              FileManager.default.fileExists(atPath: source) else { return nil }
        return URL(fileURLWithPath: source)
    }

    /// Give `target` a copy of `source`'s disk (an APFS clone: instant, no
    /// extra space until either changes). Both must be stopped.
    public static func cloneDisk(from source: String, to target: String, in folder: URL = machinesFolder) throws {
        guard let from = disk(of: source, in: folder), let to = disk(of: target, in: folder) else {
            throw EngineError.commandFailed(exitCode: 1, message: "Can't find the machines' disks in \(folder.path).")
        }
        let staged = to.deletingLastPathComponent().appending(path: "rootfs.ext4.renaming")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: from, to: staged)   // clonefile on APFS
        _ = try FileManager.default.replaceItemAt(to, withItemAt: staged)
    }

    /// Boot it (running a no-op boots a stopped machine).
    public func start(_ name: String) async throws {
        try await cli.run(["machine", "run", "-n", name, "true"])
    }

    public func stop(_ name: String) async throws {
        try await cli.run(["machine", "stop", name])
    }

    public func delete(_ name: String) async throws {
        try await cli.run(["machine", "delete", name])
    }

    public func setDefault(_ name: String) async throws {
        try await cli.run(["machine", "set-default", name])
    }

    /// Takes effect the next time the machine starts.
    public func set(_ name: String, _ settings: [Machine.Setting]) async throws {
        guard !settings.isEmpty else { return }
        try await cli.run(["machine", "set", "-n", name] + settings.map(\.argument))
    }

    /// Boot log (`boot`) or the machine's own log, last `lines`.
    public func logs(_ name: String, boot: Bool = false, lines: Int = 500) async throws -> String {
        var arguments = ["machine", "logs", "-n", String(lines)]
        if boot { arguments.append("--boot") }
        return String(decoding: try await cli.data(arguments + [name]), as: UTF8.self)
    }

    /// The arguments for an interactive login shell (for a terminal view).
    public static func shellArguments(_ name: String) -> [String] {
        ["machine", "run", "--interactive", "--tty"] + TerminalEnvironment.flags + ["-n", name]
    }
}
