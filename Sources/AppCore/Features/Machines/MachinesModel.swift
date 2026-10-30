import Foundation
import Observation
import ContainerKit

/// Container machines: list, create, start/stop, settings.
@MainActor
@Observable
final class MachinesModel {
    private let repository: MachineRepository
    private let cli: any ContainerCommanding
    private let stream: CLIStream
    private(set) var machines: [Machine] = []
    /// While renaming: what's happening ("Copying its disk…").
    private(set) var progress: String?
    /// While creating: the step under way, and the image build's last line.
    private(set) var creation: CreationStep?
    private(set) var buildLine: String?

    enum CreationStep { case preparing, starting }
    /// Old name → new name while a rename runs (the new one isn't listed yet).
    private(set) var renaming: [String: String] = [:]

    /// Machines to show: not the half-made one of a rename in progress.
    var listed: [Machine] {
        let hidden = Set(renaming.values)
        return machines.filter { !hidden.contains($0.id) }
    }
    private(set) var loaded = false
    private(set) var busy: Set<String> = []
    var error: String?
    /// Called when machines come, go or change state, so lists kept
    /// elsewhere (the sidebar's count) catch up.
    var onChange: (() -> Void)?
    /// Names `container` still holds from deleted machines: a machine
    /// can't boot under one until the engine restarts.
    private(set) var heldNames: Set<String> = []
    /// The name the last create found held.
    private(set) var heldName: String?

    init(cli: any ContainerCommanding, stream: CLIStream = CLIStream(binaryPath: Settings.shared.binaryPath)) {
        repository = MachineRepository(cli: cli)
        self.cli = cli
        self.stream = stream
    }

    /// Machine images already built (`irekobox-machine-…`).
    private(set) var preparedImages: Set<String> = []

    func refresh() async {
        if let data = try? await cli.data(["image", "list", "--format", "json"]),
           let images = try? JSONDecoder().decode([ContainerImage].self, from: data) {
            preparedImages = Set(images.map(\.shortName).filter { $0.hasPrefix("irekobox-machine-") })
        }
        do {
            let before = machines.map { "\($0.id) \($0.isRunning)" }
            machines = try await repository.list().sorted { $0.id < $1.id }
            if loaded, machines.map({ "\($0.id) \($0.isRunning)" }) != before { onChange?() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func perform(_ name: String, _ action: () async throws -> Void) async {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func start(_ name: String) async { await perform(name) { try await repository.start(name) } }
    func stop(_ name: String) async { await perform(name) { try await repository.stop(name) } }
    func delete(_ name: String) async { await perform(name) { try await remove(name) } }

    /// container has no rename: create `newName` with the same settings, give
    /// it a clone of the disk (everything installed stays), boot it, then
    /// delete the old one. On failure the new one goes and the old one
    /// is started again if it was running.
    func rename(_ name: String, to newName: String) async -> Bool {
        guard let machine = machines.first(where: { $0.id == name }) else { return false }
        guard MachineRepository.isValidName(newName), !machines.contains(where: { $0.id == newName }) else {
            error = String(localized: "“\(newName)” isn't a free, valid machine name.")
            return false
        }
        busy.insert(name)
        renaming[name] = newName
        defer { busy.remove(name); progress = nil; renaming[name] = nil }
        let wasRunning = machine.isRunning
        var created = false
        do {
            progress = String(localized: "Creating \(newName)…")
            try await repository.createStopped(image: machine.image?.reference ?? "alpine:latest", name: newName,
                                               cpus: machine.cpus, memoryBytes: machine.memory,
                                               homeMount: machine.homeMount)
            created = true
            progress = String(localized: "Stopping \(name)…")
            if wasRunning { try await repository.stop(name) }
            progress = String(localized: "Copying its disk…")
            try MachineRepository.cloneDisk(from: name, to: newName)
            if wasRunning {
                progress = String(localized: "Starting \(newName)…")
                try await repository.start(newName)
            }
            if machine.default == true { try? await repository.setDefault(newName) }
            progress = String(localized: "Removing the old name…")
            try await remove(name)
            await refresh()
            error = nil
            return true
        } catch {
            if created { try? await remove(newName) }
            if wasRunning { try? await repository.start(name) }
            await refresh()
            self.error = String(localized: "Couldn't rename \(name): \(error.localizedDescription)")
            return false
        }
    }

    /// Stop, delete, and make sure the machine's container went too:
    /// `machine delete` can drop the machine while its container keeps
    /// running, unseen, holding the name and its memory.
    private func remove(_ name: String) async throws {
        let containerId = machines.first { $0.id == name }?.containerId
        try? await repository.stop(name)
        try await repository.delete(name)
        guard let containerId, (try? await cli.data(["inspect", containerId])) != nil else { return }
        try? await cli.run(["stop", containerId])
        try? await cli.run(["delete", "--force", containerId])
    }
    func makeDefault(_ name: String) async { await perform(name) { try await repository.setDefault(name) } }

    /// Settings apply at the next start; restart a running machine to apply.
    func apply(_ name: String, _ settings: [Machine.Setting], restart: Bool) async {
        await perform(name) {
            try await repository.set(name, settings)
            if restart {
                try await repository.stop(name)
                try await repository.start(name)
            }
        }
    }

    struct MachineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Create and boot a machine. Distribution images without an init
    /// (ubuntu, debian, fedora) get a systemd image built from them once.
    func create(image: String, name: String) async -> Bool {
        let key = name.isEmpty ? image : name
        heldName = nil
        busy.insert(key)
        defer { busy.remove(key); creation = nil; buildLine = nil }
        do {
            var bootImage = image
            if MachineImage.needsPreparing(image) {
                bootImage = MachineImage.preparedTag(for: image)
                if (try? await cli.data(["image", "inspect", bootImage])) == nil {
                    try await prepare(image, as: bootImage)
                }
            }
            creation = .starting
            do {
                try await repository.create(image: bootImage, name: name.isEmpty ? nil : name)
            } catch {
                try await explainBootFailure(name, image: image, error: error)
            }
            await refresh()
            if let machine = machines.first(where: { $0.id == name }), !machine.isRunning {
                try await explainBootFailure(name, image: image, error: nil)
            }
            Milestone.createdMachine.reach()
            error = nil
            return true
        } catch {
            await refresh()
            self.error = error.localizedDescription
            return false
        }
    }

    /// Build the machine image: `image` plus systemd.
    private func prepare(_ image: String, as tag: String) async throws {
        guard let dockerfile = MachineImage.dockerfile(for: image) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "irekobox-machine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try dockerfile.write(to: folder.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        creation = .preparing
        var last: [String] = []
        do {
            for try await line in stream.lines(["build", "--progress", "plain", "--tag", tag, folder.path], mergeStderr: true) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                last = Array((last + [text]).suffix(4))
                buildLine = text
            }
        } catch {
            throw MachineError(message: String(localized: "Couldn't prepare \(image): \(last.last ?? error.localizedDescription)"))
        }
    }

    /// The machine stopped right after starting: say why, and remove it
    /// when it can never boot.
    private func explainBootFailure(_ name: String, image: String, error: Error?) async throws {
        await refresh()
        if let error, error.localizedDescription.contains("hostname(s) already exist") {
            // container sometimes keeps a deleted machine's name; the new one can't boot.
            try? await remove(name)
            heldNames.insert(name)
            heldName = name
            throw MachineError(message: String(localized: "\(name) is still held by a deleted machine until the engine restarts."))
        }
        let log = (try? await repository.logs(name, boot: false)) ?? ""
        if log.contains(MachineImage.noInitMarker) {
            try? await remove(name)
            throw MachineError(message: String(localized: "\(image) has no init system (/sbin/init), so a machine stops right after it starts. Use Ubuntu, Debian, Fedora (Irekobox adds systemd) or Alpine, or an image with an init."))
        }
        if let error { throw error }
        let tail = log.split(separator: "\n").suffix(3).joined(separator: " ")
        throw MachineError(message: String(localized: "\(name) stopped right after starting. Its log: \(tail)"))
    }

    func logs(_ name: String, boot: Bool) async -> String {
        (try? await repository.logs(name, boot: boot)) ?? ""
    }
}
