import Foundation
import ComposeKit

/// Executes a ``ComposePlan`` by running its `container` steps in order.
/// Pure orchestration over an injected ``StackCommandRunner``.
public actor ComposeRunner {
    public enum Event: Sendable {
        case started(PlanStep)
        case finished(PlanStep, StepOutcome.Status)
    }

    private let runner: StackCommandRunner

    public init(runner: StackCommandRunner) {
        self.runner = runner
    }

    /// Bring a stack up. `network`/`volume` create steps that fail because the
    /// resource already exists are skipped; a hard failure stops the run when
    /// `stopOnFailure` is set.
    @discardableResult
    public func up(
        _ plan: ComposePlan,
        workingDirectory: URL? = nil,
        stopOnFailure: Bool = true,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) async -> [StepOutcome] {
        var outcomes: [StepOutcome] = []
        for step in plan.steps {
            onEvent?(.started(step))
            let status = await execute(step,
                                       workingDirectory: workingDirectory,
                                       idempotent: step.kind == .network || step.kind == .volume)
            outcomes.append(StepOutcome(step: step, status: status))
            onEvent?(.finished(step, status))
            if status.isFailure && stopOnFailure { break }
        }
        return outcomes
    }

    /// Tear a stack down: stop + delete each run container (reverse order),
    /// then optionally remove the project's volumes and networks.
    @discardableResult
    public func down(
        _ plan: ComposePlan,
        workingDirectory: URL? = nil,
        removeVolumes: Bool = false,
        removeNetworks: Bool = true,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) async -> [StepOutcome] {
        var outcomes: [StepOutcome] = []

        let containers = plan.steps.filter { $0.kind == .run }.compactMap(\.containerName).reversed()
        for name in containers {
            for argv in [["stop", name], ["delete", name]] {
                let step = PlanStep(kind: .run, containerName: name, arguments: argv)
                onEvent?(.started(step))
                let status = await execute(step, idempotent: true) // "not found" is fine on teardown
                outcomes.append(StepOutcome(step: step, status: status))
                onEvent?(.finished(step, status))
            }
        }

        if removeVolumes {
            for step in plan.steps where step.kind == .volume {
                outcomes.append(await teardownResource(step, verb: "volume", onEvent: onEvent))
            }
        }
        if removeNetworks {
            for step in plan.steps where step.kind == .network {
                outcomes.append(await teardownResource(step, verb: "network", onEvent: onEvent))
            }
        }
        return outcomes
    }

    // MARK: - Internals

    private func teardownResource(
        _ createStep: PlanStep, verb: String,
        onEvent: (@Sendable (Event) -> Void)?
    ) async -> StepOutcome {
        // create args: [verb, "create", name] → [verb, "delete", name]
        guard let name = createStep.arguments.last else {
            return StepOutcome(step: createStep, status: .skipped(reason: "no name"))
        }
        let step = PlanStep(kind: createStep.kind, arguments: [verb, "delete", name])
        onEvent?(.started(step))
        let status = await execute(step, idempotent: true)
        onEvent?(.finished(step, status))
        return StepOutcome(step: step, status: status)
    }

    private func execute(_ step: PlanStep, workingDirectory: URL? = nil, idempotent: Bool) async -> StepOutcome.Status {
        do {
            try await runner.run(step.arguments, workingDirectory: workingDirectory)
            return .succeeded
        } catch {
            if idempotent && Self.isBenign(error) {
                return .skipped(reason: error.localizedDescription)
            }
            return .failed(message: error.localizedDescription)
        }
    }

    /// "Already exists" (on create) or "not found" (on delete) are non-fatal.
    static func isBenign(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("exist")
            || message.contains("in use")
            || message.contains("not found")
            || message.contains("no such")
    }
}
