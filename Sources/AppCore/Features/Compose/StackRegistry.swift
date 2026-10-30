import Foundation

/// A registered stack: a name (= compose project) + the compose file it loads.
struct StackEntry: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let composePath: String
}

/// The stack label written on every container so a stack's containers can be
/// found regardless of `container_name` (mirrors swarm's stack namespace label).
enum StackLabel {
    static let key = "com.irekobox.stack"
}

/// Persists the list of stacks to Application Support.
enum StackStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Irekobox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stacks.json")
    }

    static func load() -> [StackEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let stacks = try? JSONDecoder().decode([StackEntry].self, from: data) else { return [] }
        return stacks
    }

    static func save(_ stacks: [StackEntry]) throws {
        try data(for: stacks).write(to: fileURL, options: .atomic)
    }

    private static func data(for stacks: [StackEntry]) throws -> Data {
        try JSONEncoder().encode(stacks)
    }
}
