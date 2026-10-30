import Foundation
import Observation
import ContainerKit

/// Whether the registry now serves something newer for the tags your
/// containers use: once a day, public images only. Pulling the tag updates
/// the image; containers pick it up when recreated.
@MainActor
@Observable
final class ImageUpdateCheck {
    static let interval: TimeInterval = 24 * 3600

    /// Image reference → the digest the registry serves now (when it differs).
    private(set) var updates: [String: String] = [:]
    private let registry: RegistryClient
    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "checkImageUpdates") }
    }

    /// Told about each newly found update (once per published digest).
    var onNewUpdate: ((String) -> Void)?

    init(registry: RegistryClient = RegistryClient(), defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "checkImageUpdates") as? Bool ?? true
        updates = defaults.dictionary(forKey: "imageUpdates") as? [String: String] ?? [:]
    }

    /// Images that containers use (not the system ones), checked if a day passed.
    func checkIfDue(images: [ContainerImage], containers: [Container], force: Bool = false) async {
        guard isEnabled else { return }
        let last = defaults.double(forKey: "imageUpdatesChecked")
        guard force || Date().timeIntervalSince1970 - last > Self.interval else { return }
        let used = Set(containers.filter { !$0.isSystem }.map(\.configuration.image.reference))
        let candidates = images.filter { !$0.isSystem && used.contains($0.reference) }
        var found: [String: String] = [:]
        for image in candidates {
            guard let remote = try? await registry.digest(of: image.reference), remote != image.digest else { continue }
            found[image.reference] = remote
        }
        var notified = defaults.dictionary(forKey: "notifiedImageDigests") as? [String: String] ?? [:]
        for (reference, digest) in found where notified[reference] != digest {
            notified[reference] = digest
            onNewUpdate?(reference)
        }
        defaults.set(notified, forKey: "notifiedImageDigests")
        updates = found
        defaults.set(found, forKey: "imageUpdates")
        defaults.set(Date().timeIntervalSince1970, forKey: "imageUpdatesChecked")
    }

    /// After a pull: forget the update if the local image now matches.
    func pulled(_ image: ContainerImage) {
        guard let remote = updates[image.reference], remote == image.digest else { return }
        updates[image.reference] = nil
        defaults.set(updates, forKey: "imageUpdates")
    }

    func update(for image: ContainerImage) -> Bool {
        guard let remote = updates[image.reference] else { return false }
        return remote != image.digest
    }
}
