import Foundation
import Observation
import ContainerKit

/// An entry in a container directory, as listed by `find … -exec stat`.
struct ContainerFile: Identifiable, Hashable {
    enum Kind: Hashable { case directory, file, link, other }

    let path: String
    let kind: Kind
    let size: Int64
    let modified: Date
    let permissions: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// Folders first, then by name.
    var sortKey: String { (kind == .directory ? "0" : "1") + name.lowercased() }
}

enum ContainerFiles {
    /// `find <dir> -mindepth 1 -maxdepth 1 -exec stat -c '%F|%s|%Y|%A|%n' {} +`
    /// works with busybox (Alpine) and GNU coreutils alike.
    static func listCommand(_ directory: String) -> [String] {
        ["find", directory, "-mindepth", "1", "-maxdepth", "1",
         "-exec", "stat", "-c", "%F|%s|%Y|%A|%n", "{}", "+"]
    }

    /// Parse `listCommand` output. The name is the last field, so a `|` in it
    /// survives; lines that don't parse are skipped.
    static func parse(_ output: String) -> [ContainerFile] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, let size = Int64(fields[1]), let seconds = TimeInterval(fields[2]) else {
                return nil
            }
            let kind: ContainerFile.Kind
            switch fields[0] {
            case "directory": kind = .directory
            case "regular file", "regular empty file": kind = .file
            case "symbolic link": kind = .link
            default: kind = .other
            }
            return ContainerFile(path: String(fields[4]), kind: kind, size: size,
                                 modified: Date(timeIntervalSince1970: seconds),
                                 permissions: String(fields[3]))
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    /// "/a/b/c" → ["/", "/a", "/a/b", "/a/b/c"], for the path bar.
    static func ancestors(of path: String) -> [String] {
        var result = ["/"]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    /// `name` in `directory`, or "name 2.ext", "name 3.ext"… like Finder, so a
    /// download never overwrites an existing file.
    static func unusedURL(for name: String, in directory: URL,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var number = 2
        while exists(candidate) {
            candidate = directory.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// The mount `path` is in (the deepest, when mounts nest), if any.
    static func mount(containing path: String, in mounts: [Container.Mount]) -> Container.Mount? {
        mounts
            .filter { $0.volumeName != nil || $0.source != nil }
            .filter { path == $0.destination || path.hasPrefix($0.destination.hasSuffix("/") ? $0.destination : $0.destination + "/") }
            .max { $0.destination.count < $1.destination.count }
    }

    /// `head -c` of a file, enough to recognise and read most config files.
    static let previewLength = 64 * 1024

    /// Text when `data` reads as text (no NUL bytes, valid UTF-8 up to a
    /// character cut at the end), else `nil`.
    static func previewText(_ data: Data) -> String? {
        guard !data.prefix(8192).contains(0) else { return nil }
        // A multi-byte character may be cut at the limit: drop up to 3 bytes.
        for trim in 0...min(3, data.count) {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) { return text }
        }
        return nil
    }

    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// Browse a running container's filesystem, and move files in and out of it.
@MainActor
@Observable
final class FilesModel {
    let containerID: String
    private let engine: ContainerEngine

    private(set) var path: String
    private(set) var entries: [ContainerFile] = []
    private(set) var isLoading = false
    /// Why the listing is unavailable (no shell tools in the image, a missing path…).
    private(set) var listingError: String?
    /// Name of the file being copied, for progress.
    private(set) var transfer: String?
    var error: String?

    init(containerID: String, engine: ContainerEngine, path: String = "/") {
        self.containerID = containerID
        self.engine = engine
        self.path = path
    }

    func open(_ directory: String) async {
        path = directory
        await load()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await engine.execute(containerID, command: ContainerFiles.listCommand(path))
            entries = ContainerFiles.parse(String(decoding: data, as: UTF8.self))
            listingError = nil
        } catch {
            entries = []
            listingError = Self.explain(error)
        }
    }

    /// The start of a file as text, or `nil` for a binary file.
    func previewText(_ file: ContainerFile) async throws -> String? {
        let data = try await engine.execute(containerID, command: ["head", "-c", "\(ContainerFiles.previewLength)", file.path])
        return ContainerFiles.previewText(data)
    }

    /// Copy a file or folder out of the container into `directory`; returns
    /// where it landed.
    @discardableResult
    func download(_ file: ContainerFile, into directory: URL) async -> URL? {
        let destination = ContainerFiles.unusedURL(for: file.name, in: directory)
        transfer = file.name
        defer { transfer = nil }
        do {
            try await engine.copy(from: "\(containerID):\(file.path)", to: destination.path)
            return destination
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Copy local files or folders into the current directory.
    func upload(_ urls: [URL]) async {
        for url in urls {
            transfer = url.lastPathComponent
            do {
                try await engine.copy(from: url.path, to: "\(containerID):\(path)")
            } catch {
                self.error = error.localizedDescription
                break
            }
        }
        transfer = nil
        await load()
    }

    private static func explain(_ error: Error) -> String {
        let message = error.localizedDescription
        // What `container exec` 1.6 reports when the binary isn't in the image.
        if message.contains("failed to find target executable") {
            return String(localized: "This image has no find/stat tools (e.g. distroless), so its files can't be listed.")
        }
        return message
    }
}
