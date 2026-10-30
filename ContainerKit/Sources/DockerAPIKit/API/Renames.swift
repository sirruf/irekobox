import Foundation

/// What renaming needs: each container's create request (to make it again
/// under another name), and old IDs that now mean a renamed container.
public actor Renames {
    struct Spec: Sendable {
        let body: Data
        let platform: String?
    }

    private var specs: [String: Spec] = [:]
    private var aliases: [String: String] = [:]

    public init() {}

    func remember(_ name: String, _ spec: Spec) { specs[name] = spec }

    func spec(_ name: String) -> Spec? { specs[name] }

    func forget(_ name: String) {
        specs[name] = nil
        aliases = aliases.filter { $0.value != name }
    }

    func moved(_ old: String, id: String, to new: String, _ spec: Spec) {
        specs[old] = nil
        specs[new] = spec
        aliases[id] = new
    }

    /// The current name for a full ID (or a unique prefix of one) from before a rename.
    func name(forOldID reference: String) -> String? {
        if let name = aliases[reference] { return name }
        let matches = aliases.filter { $0.key.hasPrefix(reference.lowercased()) }
        return matches.count == 1 ? matches.first?.value : nil
    }
}
