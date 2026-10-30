import Foundation
import ContainerKit

/// Volume endpoints. Volumes are `container` volumes (an ext4 image each);
/// only the `local` driver exists.
public enum VolumesAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend) {
        router.add("GET", "/volumes") { request in
            await respond { try await list(request, backend) }
        }
        router.add("POST", "/volumes/create") { request in
            await respond { try await create(request, backend) }
        }
        router.add("GET", "/volumes/{name}") { request in
            await respond {
                let containers = try await backend.listContainers(all: true)
                return .json(model(try await find(request.parameters["name"]!, backend), users: containers))
            }
        }
        router.add("DELETE", "/volumes/{name}") { request in
            await respond { try await remove(request, backend) }
        }
        router.add("POST", "/volumes/prune") { request in
            await respond { try await prune(request, backend) }
        }
    }

    struct Model: Encodable {
        struct Usage: Encodable {
            let Size: Int64
            let RefCount: Int
        }
        let Name: String
        let Driver: String
        let Mountpoint: String
        let CreatedAt: String
        let Labels: [String: String]
        let Scope = "local"
        let Options: [String: String]
        var UsageData: Usage?
    }

    /// The anonymous volumes `docker run -v /path` makes (named by us
    /// `<container>-anon-<hash>`), or labelled anonymous as Docker does.
    static func isAnonymous(_ volume: Volume) -> Bool {
        if volume.configuration.labels?["com.docker.volume.anonymous"] != nil { return true }
        guard let range = volume.name.range(of: "-anon-", options: .backwards) else { return false }
        let hash = volume.name[range.upperBound...]
        return !hash.isEmpty && hash.count <= 16 && hash.allSatisfy(\.isHexDigit)
    }

    static func users(of volume: String, in containers: [Container]) -> [Container] {
        containers.filter { ($0.configuration.mounts ?? []).contains { $0.volumeName == volume } }
    }

    static func model(_ volume: Volume, users containers: [Container], size: Int64? = nil) -> Model {
        let created = volume.configuration.creationDate.flatMap(DockerTime.parse)
        var model = Model(Name: volume.name, Driver: volume.driver, Mountpoint: volume.source ?? "",
                          CreatedAt: DockerTime.string(created), Labels: volume.configuration.labels ?? [:],
                          Options: volume.configuration.options ?? [:])
        if let size {
            model.UsageData = .init(Size: size, RefCount: users(of: volume.name, in: containers).count)
        }
        return model
    }

    static func find(_ name: String, _ backend: DockerBackend) async throws -> Volume {
        guard let volume = try await backend.listVolumes().first(where: { $0.name == name }) else {
            throw DockerAPIError(404, "get \(name): no such volume")
        }
        return volume
    }

    struct ListResponse: Encodable {
        let Volumes: [Model]
        let Warnings: [String]
    }

    static func list(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["name", "label", "dangling", "driver"])
        let containers = try await backend.listContainers(all: true)
        let volumes = try await backend.listVolumes().filter { volume in
            if !filters["name"].isEmpty, !filters["name"].contains(where: { volume.name.contains($0) }) { return false }
            if !filters["driver"].isEmpty, !filters["driver"].contains(volume.driver) { return false }
            if let dangling = filters["dangling"].first {
                let unused = users(of: volume.name, in: containers).isEmpty
                if unused != (dangling == "true" || dangling == "1") { return false }
            }
            return filters.matchesLabels(volume.configuration.labels ?? [:])
        }
        return .json(ListResponse(Volumes: volumes.map { model($0, users: containers) }, Warnings: []))
    }

    struct CreateRequest: Decodable {
        let Name: String?
        let Driver: String?
        let DriverOpts: [String: String]?
        let Labels: [String: String]?
    }

    static func create(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let body = request.http.body.isEmpty ? Data("{}".utf8) : request.http.body
        guard let spec = try? JSONDecoder().decode(CreateRequest.self, from: body) else {
            throw DockerAPIError.badParameter("invalid JSON body")
        }
        if let driver = spec.Driver, !driver.isEmpty, driver != "local" {
            throw DockerAPIError.badParameter("volume driver \"\(driver)\" is not supported: only local volumes exist")
        }
        var options = spec.DriverOpts ?? [:]
        let size = options.removeValue(forKey: "size")
        if let other = options.keys.sorted().first {
            throw DockerAPIError.badParameter("volume option \"\(other)\" is not supported (only size)")
        }
        let name = spec.Name.flatMap { $0.isEmpty ? nil : $0 } ?? randomName()
        let containers = try await backend.listContainers(all: true)
        // Docker returns an existing volume of that name as is.
        if let existing = try await backend.listVolumes().first(where: { $0.name == name }) {
            return .json(model(existing, users: containers), status: 201)
        }
        try await ContainersAPI.engine { try await backend.createVolume(name, labels: spec.Labels ?? [:], size: size) }
        await FreshVolumes.shared.add(name)
        let volume = try await find(name, backend)
        return .json(model(volume, users: containers), status: 201)
    }

    static func randomName() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func remove(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let name = request.parameters["name"]!
        let volume: Volume
        do {
            volume = try await find(name, backend)
        } catch let error as DockerAPIError where error.status == 404 && request.bool("force") {
            return HTTPResponse(status: 204)
        }
        let users = users(of: volume.name, in: try await backend.listContainers(all: true))
        if !users.isEmpty {
            throw DockerAPIError(409, "remove \(name): volume is in use - [\(users.map { DockerContainer.id(for: $0) }.joined(separator: ", "))]")
        }
        try await ContainersAPI.engine { try await backend.deleteVolume(name) }
        return HTTPResponse(status: 204)
    }

    struct PruneReport: Encodable {
        let VolumesDeleted: [String]?
        let SpaceReclaimed: Int64
    }

    /// Unused volumes; anonymous ones only unless `all=true` (API ≥ 1.42).
    static func prune(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["label", "label!", "all"])
        let all = filters["all"].contains { $0 == "true" || $0 == "1" }
            || request.apiVersion < DockerAPIVersion.Version(1, 42)
        let containers = try await backend.listContainers(all: true)
        var deleted: [String] = []
        var reclaimed: Int64 = 0
        for volume in try await backend.listVolumes() {
            guard users(of: volume.name, in: containers).isEmpty, all || isAnonymous(volume),
                  filters.matchesLabels(volume.configuration.labels ?? [:]) else { continue }
            let labels = volume.configuration.labels ?? [:]
            if filters["label!"].contains(where: { labelMatches($0, labels) }) { continue }
            let size = (try? await backend.volumeDiskUsage(volume.name)) ?? 0
            do {
                try await backend.deleteVolume(volume.name)
                deleted.append(volume.name)
                reclaimed += size
            } catch {
                continue    // in use by something we can't see: leave it
            }
        }
        return .json(PruneReport(VolumesDeleted: deleted.isEmpty ? nil : deleted, SpaceReclaimed: reclaimed))
    }

    static func labelMatches(_ filter: String, _ labels: [String: String]) -> Bool {
        let parts = filter.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { return labels[parts[0]] == parts[1] }
        return labels[parts[0]] != nil
    }
}

/// Volumes made through the API and not mounted yet. Docker fills an empty
/// volume from the image the first time a container mounts it (contents,
/// owner and mode of that folder); `container` doesn't, so Irekobox does.
public actor FreshVolumes {
    public static let shared = FreshVolumes()
    private var names: Set<String> = []

    func add(_ name: String) { names.insert(name) }

    /// True once per fresh volume.
    func take(_ name: String) -> Bool { names.remove(name) != nil }

    /// Copy `path` of `image` into each volume, as root, keeping owners and
    /// modes, after removing the empty `lost+found` a new ext4 volume has
    /// (postgres 18 refuses a data folder that isn't empty). Best effort: an
    /// image without a shell leaves the volume as it is.
    static func copyUp(_ mounts: [(name: String, path: String)], image: String, container: String,
                       backend: DockerBackend) async {
        for (index, mount) in mounts.enumerated() {
            let helper = "\(container)-copyup-\(index)"
            let script = """
            rmdir /.irekobox-copyup/lost+found 2>/dev/null
            s=\(shellQuote(mount.path)); [ -d "$s" ] || exit 0
            cp -a "$s"/. /.irekobox-copyup/ && chown "$(stat -c %u:%g "$s")" /.irekobox-copyup \\
              && chmod "$(stat -c %a "$s")" /.irekobox-copyup
            """
            do {
                try await backend.createContainer(["--name", helper, "--rm", "--entrypoint", "/bin/sh", "-u", "0",
                                                   "-v", "\(mount.name):/.irekobox-copyup", image, "-c", script])
                try await backend.startContainer(helper)
                _ = try await backend.waitContainer(helper)
            } catch {}
            // `--rm` usually removes it; a stop that settles late can keep it, so retry.
            for attempt in 0..<5 {
                guard (try? await backend.listContainers(all: true))?.contains(where: { $0.id == helper }) == true else { break }
                try? await backend.deleteContainer(helper, force: true)
                if attempt < 4 { try? await Task.sleep(for: .milliseconds(400)) }
            }
        }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
