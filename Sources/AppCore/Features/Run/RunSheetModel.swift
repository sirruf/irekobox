import Foundation
import Observation
import ContainerKit
import MigrationKit

/// State of the Run sheet: the form, or a pasted `docker run` command, and
/// running it.
@MainActor
@Observable
final class RunSheetModel {
    enum Mode: String, CaseIterable, Identifiable {
        case form = "Image"
        case paste = "Paste docker run"
        var id: String { rawValue }
    }

    var mode: Mode = .form
    var config = RunConfiguration()
    var pasted = "" {
        didSet { translate() }
    }
    private(set) var translation: DockerRunTranslation?
    private(set) var translationError: String?
    private(set) var isRunning = false
    var runError: String?

    /// Names and host ports already taken, for the checks.
    var existingNames: Set<String> = []
    var usedHostPorts: Set<Int> = []

    init(image: String = "") {
        config.image = image
    }

    // MARK: - What the image declares

    /// Ports, volumes and required variables of the chosen image, from its
    /// config (inspected locally, else read from the registry).
    struct ImageHints: Equatable {
        var ports: [Int] = []
        var volumes: [String] = []
        /// Variables the image won't start without (known images only).
        var required: [String] = []
    }

    private(set) var hints: ImageHints?
    /// What the hints were filled into, so a new image replaces them and
    /// anything the user typed is left alone.
    @ObservationIgnored private var filled: (ports: [UUID], mounts: [UUID], variables: [UUID]) = ([], [], [])

    /// Look `image` up and fill in what it needs (ports, a volume, required
    /// variables) where the user hasn't put anything.
    func loadHints(for image: String, engine: any ContainerEngine, local: [String],
                   registry: RegistryClient = RegistryClient()) async {
        let image = image.trimmingCharacters(in: .whitespaces)
        guard let reference = ImageReference(image), !image.hasSuffix(":") else { return }
        var config: ImageDetails.OCIConfig?
        if let match = local.first(where: { $0 == image || $0 == reference.canonical }) {
            config = (try? await engine.inspectImage(match))?.variant()?.config
        } else {
            config = try? await registry.config(of: reference.canonical)
        }
        guard !Task.isCancelled, self.config.image.trimmingCharacters(in: .whitespaces) == image else { return }
        let ports = (config?.config?.ExposedPorts?.keys ?? [:].keys).compactMap { key -> Int? in
            let parts = key.split(separator: "/")
            guard parts.count < 2 || parts[1] == "tcp" else { return nil }
            return Int(parts[0])
        }.sorted()
        let volumes = (config?.config?.Volumes?.keys).map(Array.init)?.sorted() ?? []
        let hints = ImageHints(ports: ports, volumes: volumes,
                               required: Self.requiredVariables(repository: reference.repository))
        self.hints = hints
        apply(hints)
    }

    private func apply(_ hints: ImageHints) {
        // Replace what earlier hints filled in, if it's still untouched.
        config.ports.removeAll { port in filled.ports.contains(port.id) }
        config.mounts.removeAll { mount in filled.mounts.contains(mount.id) }
        config.variables.removeAll { variable in filled.variables.contains(variable.id) && variable.value.isEmpty }
        filled = ([], [], [])
        if config.ports.isEmpty {
            var taken = usedHostPorts
            for port in hints.ports.prefix(4) {
                var host = port
                while taken.contains(host) && host < port + 100 { host += 1 }
                taken.insert(host)
                let entry = RunConfiguration.Port(host: String(host), container: String(port))
                config.ports.append(entry)
                filled.ports.append(entry.id)
            }
        }
        if config.mounts.isEmpty {
            let base = Self.volumeBase(name: config.name, image: config.image)
            for (index, path) in hints.volumes.prefix(3).enumerated() {
                let entry = RunConfiguration.Mount(source: index == 0 ? "\(base)-data" : "\(base)-data-\(index + 1)",
                                                   target: path)
                config.mounts.append(entry)
                filled.mounts.append(entry.id)
            }
        }
        for key in hints.required where !config.variables.contains(where: { $0.key == key }) {
            let entry = RunConfiguration.Variable(key: key, value: "")
            config.variables.append(entry)
            filled.variables.append(entry.id)
        }
    }

    /// `postgres-1` → `postgres-1`; no name → the image's last path part.
    static func volumeBase(name: String, image: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        let last = image.split(separator: "/").last.map(String.init) ?? image
        return String(last.split(separator: ":").first ?? Substring(last))
    }

    /// Variables well-known images refuse to start without.
    static func requiredVariables(repository: String) -> [String] {
        switch repository {
        case "library/postgres": return ["POSTGRES_PASSWORD"]
        case "library/mysql": return ["MYSQL_ROOT_PASSWORD"]
        case "library/mariadb": return ["MARIADB_ROOT_PASSWORD"]
        default: return []
        }
    }

    var issues: [RunConfiguration.Issue] {
        let required = (hints?.required ?? []).compactMap { key -> RunConfiguration.Issue? in
            guard let variable = config.variables.first(where: { $0.key == key }),
                  variable.value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return RunConfiguration.Issue(field: .variable(variable.id), severity: .error,
                                          message: String(localized: "The image won't start without a value for \(key)."))
        }
        return config.issues(existingNames: existingNames, usedHostPorts: usedHostPorts) + required
    }

    /// Issues to show next to a field. A missing image is not an error to
    /// point at before anything was typed; Run stays disabled meanwhile.
    func issues(for field: RunConfiguration.Issue.Field) -> [RunConfiguration.Issue] {
        let imageMissing = config.image.trimmingCharacters(in: .whitespaces).isEmpty
        return issues.filter { $0.field == field && !(imageMissing && $0.field == .image) }
    }

    var canRun: Bool {
        guard !isRunning else { return false }
        switch mode {
        case .form: return !issues.contains { $0.severity == .error }
        case .paste: return translation != nil
        }
    }

    /// What will be run, for the preview.
    var commandLine: String {
        switch mode {
        case .form:
            guard !config.image.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
            return config.commandLine()
        case .paste: return translation.map { "container " + detached($0.arguments).map(ContainerList.shellQuoted).joined(separator: " ") } ?? ""
        }
    }

    /// The name the new container will have, when known.
    var containerName: String? {
        switch mode {
        case .form:
            let name = config.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        case .paste:
            guard let args = translation?.arguments, let index = args.firstIndex(of: "--name"),
                  args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
    }

    func apply(_ suggestion: RunConfiguration.Suggestion) {
        switch suggestion {
        case .hostPort(let portID, let value):
            if let index = config.ports.firstIndex(where: { $0.id == portID }) {
                config.ports[index].host = value
            }
        }
    }

    /// Run it; `true` once the container started.
    func run(engine: any ContainerEngine) async -> Bool {
        guard canRun else { return false }
        isRunning = true
        defer { isRunning = false }
        runError = nil
        let arguments: [String]
        switch mode {
        case .form: arguments = config.arguments()
        case .paste: arguments = Array(detached(translation?.arguments ?? []).dropFirst())
        }
        do {
            try await engine.runContainer(arguments)
            return true
        } catch {
            runError = error.localizedDescription
            return false
        }
    }

    private func translate() {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            translation = nil
            translationError = nil
            return
        }
        do {
            translation = try DockerRunTranslator().translate(text)
            translationError = nil
        } catch {
            translation = nil
            translationError = error.localizedDescription
        }
    }

    /// `container run` without `--detach` would attach and never return.
    private func detached(_ arguments: [String]) -> [String] {
        guard arguments.first == "run", !arguments.contains("--detach"), !arguments.contains("-d") else {
            return arguments
        }
        return ["run", "--detach"] + arguments.dropFirst()
    }
}
