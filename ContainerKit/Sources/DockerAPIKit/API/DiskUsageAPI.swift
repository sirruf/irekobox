import Foundation
import ContainerKit

/// `GET /system/df` in both shapes: the per-type usage summaries of API
/// 1.52+ and the item lists older clients read.
public enum DiskUsageAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend) {
        router.add("GET", "/system/df") { request in
            await respond { try await usage(request, backend) }
        }
    }

    struct Usage<Item: Encodable>: Encodable {
        let ActiveCount: Int
        let TotalCount: Int
        let Reclaimable: Int64
        let TotalSize: Int64
        /// Verbose only.
        var Items: [Item]?
    }

    struct ImageItem: Encodable {
        let Id: String
        let ParentId = ""
        let RepoTags: [String]
        let RepoDigests: [String]
        let Created: Int64
        let Size: Int64
        let SharedSize: Int64 = 0
        let VirtualSize: Int64
        let Labels: [String: String] = [:]
        let Containers: Int
    }

    struct Response: Encodable {
        let ImageUsage: Usage<ImageItem>?
        let ContainerUsage: Usage<ContainerModels.Summary>?
        let VolumeUsage: Usage<VolumesAPI.Model>?
        let BuildCacheUsage: Usage<String>?
        // Pre-1.52.
        let LayersSize: Int64
        let Images: [ImageItem]?
        let Containers: [ContainerModels.Summary]?
        let Volumes: [VolumesAPI.Model]?
        let BuildCache: [String]?
    }

    static func usage(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let types = Set(request.http.queryValues("type"))
        func wanted(_ type: String) -> Bool { types.isEmpty || types.contains(type) }
        let legacy = request.apiVersion < DockerAPIVersion.Version(1, 52)
        let verbose = request.bool("verbose") || legacy
        let containers = try await backend.listContainers(all: true).filter { !$0.isSystem }

        var imageUsage: Usage<ImageItem>?
        var imageItems: [ImageItem]?
        if wanted("image") {
            let images = try await ImageDirectory(backend: backend).all()
            var total: Int64 = 0
            var reclaimable: Int64 = 0
            var active = 0
            var items: [ImageItem] = []
            for image in images {
                let users = containers.filter { $0.configuration.image.descriptor.digest == image.primary.digest }.count
                let size = Int64(image.size)
                total += size
                if users > 0 { active += 1 } else { reclaimable += size }
                items.append(ImageItem(Id: image.id, RepoTags: image.repoTags, RepoDigests: image.repoDigests,
                                       Created: Int64(image.created?.timeIntervalSince1970 ?? 0), Size: size,
                                       VirtualSize: size, Containers: users))
            }
            imageUsage = Usage(ActiveCount: active, TotalCount: images.count, Reclaimable: reclaimable, TotalSize: total)
            imageItems = items
        }

        var containerUsage: Usage<ContainerModels.Summary>?
        var containerItems: [ContainerModels.Summary]?
        if wanted("container") {
            // A container's writable layer lives in its VM's disk image,
            // which the runtime doesn't measure: sizes are 0.
            let running = containers.filter(\.state.isRunning).count
            containerUsage = Usage(ActiveCount: running, TotalCount: containers.count, Reclaimable: 0, TotalSize: 0)
            let directory = ContainerDirectory(backend: backend)
            var items: [ContainerModels.Summary] = []
            for container in containers { items.append(ContainerModels.summary(await directory.describe(container))) }
            containerItems = items
        }

        var volumeUsage: Usage<VolumesAPI.Model>?
        var volumeItems: [VolumesAPI.Model]?
        if wanted("volume") {
            let volumes = try await backend.listVolumes()
            var total: Int64 = 0
            var reclaimable: Int64 = 0
            var active = 0
            var items: [VolumesAPI.Model] = []
            for volume in volumes {
                let size = (try? await backend.volumeDiskUsage(volume.name)) ?? 0
                let model = VolumesAPI.model(volume, users: containers, size: size)
                total += size
                if (model.UsageData?.RefCount ?? 0) > 0 { active += 1 } else { reclaimable += size }
                items.append(model)
            }
            volumeUsage = Usage(ActiveCount: active, TotalCount: volumes.count, Reclaimable: reclaimable, TotalSize: total)
            volumeItems = items
        }

        let buildUsage = wanted("build-cache") ? Usage<String>(ActiveCount: 0, TotalCount: 0, Reclaimable: 0, TotalSize: 0) : nil
        if verbose {
            imageUsage?.Items = imageItems
            containerUsage?.Items = containerItems
            volumeUsage?.Items = volumeItems
        }
        return .json(Response(
            ImageUsage: imageUsage, ContainerUsage: containerUsage, VolumeUsage: volumeUsage, BuildCacheUsage: buildUsage,
            LayersSize: imageUsage?.TotalSize ?? 0,
            Images: verbose ? imageItems : nil, Containers: verbose ? containerItems : nil,
            Volumes: verbose ? volumeItems : nil, BuildCache: verbose ? [] : nil))
    }
}
