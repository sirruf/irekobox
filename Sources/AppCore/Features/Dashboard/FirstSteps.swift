import SwiftUI
import ContainerKit

/// Milestones a newcomer reaches once (kept in UserDefaults).
enum Milestone: String {
    case openedInBrowser = "milestone.openedInBrowser"
    case createdMachine = "milestone.createdMachine"
    case ranKubernetesApp = "milestone.ranKubernetesApp"

    var reached: Bool { UserDefaults.standard.bool(forKey: rawValue) }
    func reach() { UserDefaults.standard.set(true, forKey: rawValue) }
}

/// "First steps" on the Overview: a strip with a short tour through what the
/// app does; done steps tick themselves off, the next one is a link that
/// starts it, its explanation in the tooltip.
struct FirstSteps: View {
    @Environment(AppState.self) private var app
    @AppStorage("firstStepsHidden") private var hidden = false

    private struct Step: Identifiable {
        let id: String
        /// Short, for the strip.
        let title: String
        let detail: String
        let done: Bool
        let action: String
        let run: () -> Void
    }

    private var steps: [Step] {
        let containers = app.model.containers.filter { !$0.isSystem }
        let hasCompose = containers.contains { ContainerList.project(of: $0) != nil } || !StackStore.load().isEmpty
        return [
            Step(id: "run", title: String(localized: "Run a container"),
                 detail: String(localized: "Start an app from an image, for example nginx:alpine, a web server."),
                 done: !containers.isEmpty, action: String(localized: "Run Container…")) { app.requestRun() },
            Step(id: "open", title: String(localized: "Open it in the browser"),
                 detail: String(localized: "Publish a port, then click it: localhost:8080 shows what runs inside."),
                 done: Milestone.openedInBrowser.reached, action: String(localized: "Go to Containers")) { app.section = .containers },
            Step(id: "compose", title: String(localized: "Run a compose app"),
                 detail: String(localized: "A compose.yaml starts a web app with its database together; see how they connect on the map."),
                 done: hasCompose, action: String(localized: "Go to Compose")) { app.section = .compose },
            Step(id: "machine", title: String(localized: "Get a Linux shell"),
                 detail: String(localized: "A machine is a Linux system with your home folder: install tools and try things."),
                 done: Milestone.createdMachine.reached, action: String(localized: "Go to Machines")) { app.section = .machines },
            Step(id: "kube", title: String(localized: "Run an app on Kubernetes"),
                 detail: String(localized: "Make a local cluster and run an app; it explains each Kubernetes object it makes."),
                 done: Milestone.ranKubernetesApp.reached, action: String(localized: "Go to Kubernetes")) { app.section = .kubernetes },
        ]
    }

    var body: some View {
        let steps = self.steps
        let done = steps.filter(\.done).count
        let next = steps.first { !$0.done }
        if !hidden, let next {
            HStack(spacing: DS.Spacing.l) {
                Text("First steps · \(done) of \(steps.count)").font(.headline.monospacedDigit())
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Spacing.l) { ForEach(steps) { item($0, next: next) } }
                    HStack(spacing: DS.Spacing.l) {
                        ForEach(steps.filter { !$0.done }) { item($0, next: next) }
                    }
                    item(next, next: next)
                }
                Spacer(minLength: 0)
                Button("Hide") { hidden = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DS.accent)
                    .help("You can show them again in Settings")
            }
            .padding(.horizontal, DS.Spacing.l + DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.l)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.accent.opacity(0.06)))
            .hairline(RoundedRectangle(cornerRadius: DS.Radius.panel), DS.accent.opacity(0.25))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("First steps, \(done) of \(steps.count) done")
        }
    }

    @ViewBuilder
    private func item(_ step: Step, next: Step) -> some View {
        if step.done {
            Label(step.title, systemImage: "checkmark")
                .foregroundStyle(Tone.positive.text)
                .accessibilityLabel("Done: \(step.title)")
        } else if step.id == next.id {
            Button { step.run() } label: {
                Text(verbatim: "\(step.title) →").fontWeight(.semibold)
            }
            .buttonStyle(.link)
            .help(step.detail)
        } else {
            Text(step.title).foregroundStyle(.secondary).help(step.detail)
        }
    }
}
