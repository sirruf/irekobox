import Foundation

/// An executable plan: an ordered list of `container` invocations plus warnings.
/// Pure data — execution happens elsewhere (e.g. via ContainerKit).
public struct ComposePlan: Sendable, Hashable {
    public let projectName: String
    public let steps: [PlanStep]
    public let warnings: [PlanWarning]

    public init(projectName: String, steps: [PlanStep], warnings: [PlanWarning]) {
        self.projectName = projectName
        self.steps = steps
        self.warnings = warnings
    }
}

/// One `container` command in the plan.
public struct PlanStep: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case network, volume, build, run }

    public let id = UUID()
    public let kind: Kind
    public let service: String?
    public let containerName: String?
    /// Full argv passed to the `container` binary, e.g. `["run", "-d", …]`.
    public let arguments: [String]

    public init(kind: Kind, service: String? = nil, containerName: String? = nil, arguments: [String]) {
        self.kind = kind
        self.service = service
        self.containerName = containerName
        self.arguments = arguments
    }

    /// Human-readable form, e.g. `container run -d --name web …`.
    public var displayCommand: String {
        (["container"] + arguments).joined(separator: " ")
    }
}

/// A diagnostic emitted while planning.
public struct PlanWarning: Sendable, Hashable {
    public enum Severity: String, Sendable {
        case info        // handled at app level (depends_on, restart, …)
        case partial     // mapped with reduced fidelity
        case unsupported // no analog in `container`; ignored
    }

    public let service: String?
    public let field: String
    public let message: String
    public let severity: Severity

    public init(service: String?, field: String, message: String, severity: Severity) {
        self.service = service
        self.field = field
        self.message = message
        self.severity = severity
    }
}

public enum ComposePlanError: Error, LocalizedError {
    case dependencyCycle([String])
    case missingImage(service: String)
    case unknownDependency(service: String, dependency: String)

    public var errorDescription: String? {
        switch self {
        case .dependencyCycle(let nodes):
            return String(localized: "depends_on cycle among: \(nodes.joined(separator: ", "))")
        case .missingImage(let service):
            return String(localized: "Service `\(service)` has neither `image` nor `build`.")
        case .unknownDependency(let service, let dependency):
            return String(localized: "Service `\(service)` depends on unknown service `\(dependency)`.")
        }
    }
}
