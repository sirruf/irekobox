import Foundation
import ContainerKit

/// Images as Docker clients see them: one entry per image (index digest)
/// with all its tags, hiding `container`'s own (init and builder) images.
struct DockerImage: Sendable {
    /// `sha256:<index digest>`, the same value containers report as ImageID.
    let id: String
    let references: [ContainerImage]

    var primary: ContainerImage { references[0] }
    var repoTags: [String] {
        references.compactMap { ImageReference($0.reference)?.familiar }.sorted()
    }
    var repoDigests: [String] {
        Array(Set(references.compactMap { image -> String? in
            guard let reference = ImageReference(image.reference) else { return nil }
            let repository = reference.registry == "docker.io" ? reference.familiar.split(separator: ":").first.map(String.init) ?? ""
                : "\(reference.registry)/\(reference.repository)"
            return "\(repository)@\(image.digest)"
        })).sorted()
    }
    /// The native variant's size, else everything.
    var size: Int {
        let native = (primary.variants ?? []).first { $0.platform?.architecture == "arm64" }?.size
        return native ?? primary.totalSize
    }
    var created: Date? { primary.configuration.creationDate.flatMap(DockerTime.parse) }
}

struct ImageDirectory: Sendable {
    let backend: DockerBackend

    func all() async throws -> [DockerImage] {
        let images = try await backend.listImages().filter { !$0.isSystem }
        let grouped = Dictionary(grouping: images, by: \.digest)
        return grouped.map { digest, references in
            let image = DockerImage(id: digest.hasPrefix("sha256:") ? digest : "sha256:\(digest)",
                                    references: references.sorted { $0.reference < $1.reference })
            return (image, image.created ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// By reference (`alpine`, `alpine:3.20`, `docker.io/library/alpine:latest`,
    /// `alpine@sha256:…`) or by ID / unique ID prefix (with or without `sha256:`).
    /// Returns the image and the matched reference (nil when found by ID).
    func resolve(_ name: String) async throws -> (DockerImage, ContainerImage?) {
        let images = try await all()
        if let reference = ImageReference(name) {
            for image in images {
                if let match = image.references.first(where: { ImageReference($0.reference)?.canonical == reference.canonical }) {
                    return (image, match)
                }
                if let digest = reference.digest, image.primary.digest == digest {
                    return (image, nil)
                }
            }
        }
        let hex = name.hasPrefix("sha256:") ? String(name.dropFirst(7)) : name
        if hex.count >= 4, hex.allSatisfy(\.isHexDigit) {
            let matches = images.filter { $0.id.dropFirst(7).hasPrefix(hex.lowercased()) }
            if matches.count > 1 { throw DockerAPIError(400, "multiple IDs found with provided prefix: \(name)") }
            if let image = matches.first { return (image, nil) }
        }
        throw DockerAPIError(404, "No such image: \(name)")
    }
}
