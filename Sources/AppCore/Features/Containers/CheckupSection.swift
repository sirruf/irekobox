import SwiftUI
import ContainerKit

/// "Something's off?": checks a running container's ports, the memory its
/// VM holds and the folders it shares, and says what to do.
struct CheckupSection: View {
    let container: Container
    /// Off inside a card that has its own title.
    var showsTitle = true
    @Environment(AppState.self) private var app
    @State private var findings: [ContainerCheckup.Finding]?
    @State private var running = false
    @State private var checked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack {
                if showsTitle { SectionHeader("Checkup") }
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Button(findings == nil ? "Check" : "Check Again") { Task { await run() } }
                        .controlSize(.small)
                        .accessibilityIdentifier("containers.checkup")
                }
            }
            if let findings {
                if findings.isEmpty {
                    Text("No ports or shared folders to check.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(findings) { row($0) }
            } else if !running {
                Text("Ports that don't answer, memory the VM keeps, slow shared folders.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: container.id) { findings = nil }
    }

    private func row(_ finding: ContainerCheckup.Finding) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: Self.symbol(finding.level))
                .foregroundStyle(Self.tone(finding.level).text)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(finding.title).font(.callout.weight(.medium))
                Text(finding.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix {
                    Text(fix).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func run() async {
        running = true
        defer { running = false }
        findings = await CheckupRunner.run(container, engine: app.engine)
    }

    static func symbol(_ level: ContainerCheckup.Finding.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    static func tone(_ level: ContainerCheckup.Finding.Level) -> Tone {
        switch level {
        case .ok: return .positive
        case .info: return .info
        case .warning: return .warning
        case .problem: return .critical
        }
    }
}

/// Every running container's checkup at once (Settings › Troubleshoot).
struct AllContainersCheckup: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var results: [(String, [ContainerCheckup.Finding])] = []
    @State private var running = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Container Checkup").font(.headline)
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            .padding(DS.Spacing.l)
            Divider()
            List {
                if !running && results.isEmpty {
                    Text("No running containers.").foregroundStyle(.secondary)
                }
                ForEach(results, id: \.0) { name, findings in
                    Section(name) {
                        let issues = findings.filter { $0.level > .ok }
                        if issues.isEmpty {
                            Label("Nothing to fix", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.positive.text)
                        }
                        ForEach(issues) { finding in
                            HStack(alignment: .top, spacing: DS.Spacing.s) {
                                Image(systemName: CheckupSection.symbol(finding.level))
                                    .foregroundStyle(CheckupSection.tone(finding.level).text)
                                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                    Text(finding.title).font(.callout.weight(.medium))
                                    Text(finding.detail).font(.callout).foregroundStyle(.secondary)
                                    if let fix = finding.fix { Text(fix).font(.callout).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.m)
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            let containers = app.model.containers.filter { $0.state.isRunning && !$0.isSystem }
            for container in containers.sorted(by: { $0.id < $1.id }) {
                let findings = await CheckupRunner.run(container, engine: app.engine)
                results.append((container.id, findings))
            }
            running = false
        }
    }
}
