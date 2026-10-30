import Foundation
import ComposeKit
import ContainerKit

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
    ///
    /// A volume this up made (not one that existed) is filled from the image
    /// before the first service mounts it, as Docker does (see
    /// ``VolumeCopyUp``). Anonymous volumes get a name derived from the
    /// container and mount path, so they can be filled too and are found
    /// again when the container is made again.
    @discardableResult
    public func up(
        _ plan: ComposePlan,
        workingDirectory: URL? = nil,
        stopOnFailure: Bool = true,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) async -> [StepOutcome] {
        var outcomes: [StepOutcome] = []
        /// Volumes made by this up and not mounted yet.
        var fresh: Set<String> = []
        steps: for step in plan.steps {
            var step = step
            var failure: String?
            if step.kind == .run, let run = RunArguments(step.arguments), let container = step.containerName {
                for anonymous in run.anonymousVolumes {
                    let create = Self.anonymousVolumeStep(anonymous, of: step, container: container)
                    let status = await perform(create, idempotent: true, onEvent: onEvent)
                    outcomes.append(StepOutcome(step: create, status: status))
                    if status == .succeeded { fresh.insert(create.arguments.last!) }
                    if status.isFailure && stopOnFailure { break steps }
                }
                step = Self.naming(run.anonymousVolumes, of: step, container: container)
                let mounts = RunArguments(step.arguments)?.namedVolumes ?? []
                for (index, mount) in mounts.enumerated() where fresh.remove(mount.name) != nil {
                    if let message = await fill(mount, image: run.image, container: container, index: index) {
                        failure = message
                        break
                    }
                }
            }
            onEvent?(.started(step))
            let status: StepOutcome.Status
            if let failure {
                status = .failed(message: failure)
            } else {
                status = await execute(step, workingDirectory: workingDirectory,
                                       idempotent: step.kind == .network || step.kind == .volume)
            }
            outcomes.append(StepOutcome(step: step, status: status))
            onEvent?(.finished(step, status))
            if step.kind == .volume, status == .succeeded, let name = step.arguments.last {
                fresh.insert(name)
            }
            if status.isFailure && stopOnFailure { break }
        }
        return outcomes
    }

    /// Tear a stack down: stop + delete each run container (reverse order),
    /// then optionally remove the project's volumes (the anonymous ones `up`
    /// named included) and networks.
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
                let status = await perform(step, idempotent: true, onEvent: onEvent) // "not found" is fine on teardown
                outcomes.append(StepOutcome(step: step, status: status))
            }
        }

        if removeVolumes {
            for step in plan.steps where step.kind == .volume {
                outcomes.append(await teardownResource(step, verb: "volume", onEvent: onEvent))
            }
            for step in plan.steps where step.kind == .run {
                guard let run = RunArguments(step.arguments), let container = step.containerName else { continue }
                for anonymous in run.anonymousVolumes {
                    let create = Self.anonymousVolumeStep(anonymous, of: step, container: container)
                    outcomes.append(await teardownResource(create, verb: "volume", onEvent: onEvent))
                }
            }
        }
        if removeNetworks {
            for step in plan.steps where step.kind == .network {
                outcomes.append(await teardownResource(step, verb: "network", onEvent: onEvent))
            }
        }
        return outcomes
    }

    // MARK: - Volumes

    /// The `volume create` for an anonymous volume of `step`.
    static func anonymousVolumeStep(_ volume: RunArguments.AnonymousVolume, of step: PlanStep,
                                    container: String) -> PlanStep {
        let name = VolumeCopyUp.anonymousVolumeName(container: container, path: volume.target)
        return PlanStep(kind: .volume, service: step.service, arguments: ["volume", "create", name])
    }

    /// `step` with each anonymous `--mount` written as a named `--volume`.
    static func naming(_ volumes: [RunArguments.AnonymousVolume], of step: PlanStep, container: String) -> PlanStep {
        guard !volumes.isEmpty else { return step }
        var arguments = step.arguments
        for volume in volumes {
            let name = VolumeCopyUp.anonymousVolumeName(container: container, path: volume.target)
            arguments[volume.valueIndex - 1] = "--volume"
            arguments[volume.valueIndex] = "\(name):\(volume.target)\(volume.readOnly ? ":ro" : "")"
        }
        return PlanStep(kind: step.kind, service: step.service, containerName: step.containerName, arguments: arguments)
    }

    /// Fill a fresh volume from `image` with a helper container, and remove
    /// the helper before returning: an ext4 volume must never be mounted by
    /// two VMs, so the service may start only once the helper is gone. The
    /// copy itself is best effort (an image without a shell leaves the
    /// volume empty); a helper that can't be removed is the error returned.
    private func fill(_ mount: RunArguments.NamedVolume, image: String, container: String, index: Int) async -> String? {
        let helper = VolumeCopyUp.helperName(container: container, index: index)
        let arguments = ["run"] + VolumeCopyUp.helperArguments(name: helper, volume: mount.name,
                                                                image: image, sourcePath: mount.target)
        // Foreground: returns once the helper has exited.
        try? await runner.run(arguments, workingDirectory: nil)
        do {
            // Synchronous in the CLI: the container is gone when this returns.
            try await runner.run(["delete", "--force", helper], workingDirectory: nil)
        } catch let error where Self.isBenign(error) {
            // Never made (the image wasn't found, say): nothing to remove.
        } catch {
            return "\(helper): \(error.localizedDescription)"
        }
        return nil
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
        let status = await perform(step, idempotent: true, onEvent: onEvent)
        return StepOutcome(step: step, status: status)
    }

    /// Execute `step` between its started and finished events.
    private func perform(_ step: PlanStep, idempotent: Bool,
                         onEvent: (@Sendable (Event) -> Void)?) async -> StepOutcome.Status {
        onEvent?(.started(step))
        let status = await execute(step, idempotent: idempotent)
        onEvent?(.finished(step, status))
        return status
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
