import SwiftUI
import ContainerKit

/// First run: install (or update) Apple's `container`, start the engine, and
/// choose whether to keep watching containers in the background.
struct SetupView: View {
    @Environment(AppState.self) private var app
    @State private var installer = ContainerInstaller()
    @State private var isStarting = false
    @State private var agentEnabled = true

    enum Step: Int, CaseIterable {
        case install, start, background

        var title: String {
            switch self {
            case .install: return String(localized: "Install container")
            case .start: return String(localized: "Start the engine")
            case .background: return String(localized: "Finish")
            }
        }
    }

    private var installed: Bool { app.binaryAvailable && app.cliSupported }

    private var current: Step {
        if !installed { return .install }
        if !app.servicesRunning { return .start }
        return .background
    }

    var body: some View {
        HStack(spacing: 0) {
            steps
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(DS.subtleFill)
            Divider()
            Group {
                switch current {
                case .install: installStep
                case .start: startStep
                case .background: backgroundStep
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(DS.Spacing.xl * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            app.setupInProgress = true
            agentEnabled = app.backgroundAgentEnabled
        }
        .onDisappear { app.setupInProgress = false }
        // While Installer is open, notice when it has done its job.
        .task(id: installer.phase == .installing) {
            guard installer.phase == .installing else { return }
            while !Task.isCancelled && !installed {
                try? await Task.sleep(for: .seconds(2))
                await app.checkCLIVersion()
            }
            if installed {
                installer.reset()
                await app.refreshSystem()
            }
        }
        .task {
            // The release to install; usually known from the daily check.
            if app.updates.latest == nil { await app.updates.checkIfDue(force: true) }
        }
        .accessibilityIdentifier("setup")
    }

    // MARK: - Step list

    private var steps: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.s) {
                BrandLogo(size: 28)
                Text("Set up").font(.title3.weight(.semibold))
            }
            .padding(.bottom, DS.Spacing.s)
            ForEach(Step.allCases, id: \.self) { step in
                HStack(spacing: DS.Spacing.s) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue < current.rawValue ? Tone.positive.fill
                                  : step == current ? DS.accent : Color.secondary.opacity(0.2))
                            .frame(width: 22, height: 22)
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)").font(.caption.weight(.semibold))
                                .foregroundStyle(step == current ? .white : .secondary)
                        }
                    }
                    Text(step.title)
                        .fontWeight(step == current ? .semibold : .regular)
                        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(step.rawValue < current.rawValue ? "done" : step == current ? "current" : "")
            }
        }
        .padding(DS.Spacing.xl)
    }

    // MARK: - Steps

    private var installStep: some View {
        let outdated = app.binaryAvailable && !app.cliSupported
        let version = app.updates.latest?.version
        return VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text(outdated ? "Update Apple's container" : "Install Apple's container")
                .font(.largeTitle.weight(.bold))
            Group {
                if !outdated {
                    Text("Irekobox runs Linux containers with Apple's open-source container tool: each container gets its own lightweight virtual machine.")
                } else if let installed = ContainerInstaller.parseVersion(app.cliVersionOutput ?? "") {
                    Text("Irekobox needs container \(ContainerInstaller.minimumVersion) or later; this Mac has \(installed).")
                } else {
                    Text("Irekobox needs container \(ContainerInstaller.minimumVersion) or later; this Mac has an older version.")
                }
            }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch installer.phase {
            case .idle, .failed:
                HStack(spacing: DS.Spacing.m) {
                    Button {
                        if let version { Task { await installer.install(version: version) } }
                    } label: {
                        Text(version.map { outdated ? String(localized: "Update to container \($0)") : String(localized: "Install container \($0)") }
                             ?? String(localized: "Looking up the latest release…"))
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(version == nil)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.install")
                    Link("Download manually", destination: URL(string: "https://github.com/apple/container/releases")!)
                }
                if case .failed(let message) = installer.phase {
                    NoticeBanner(tone: .critical, title: "Not installed", message: message)
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text("Downloading the installer from GitHub…").font(.caption).foregroundStyle(.secondary)
                }
            case .verifying:
                Label("Checking Apple's signature and notarization…", systemImage: "checkmark.seal")
            case .installing:
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    HStack(spacing: DS.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Finish the installation in Installer. It asks for your administrator password.")
                    }
                    Text("This screen moves on by itself when container is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Label("The package is signed and notarized by Apple; it's verified before it opens.",
                  systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            Text("Requires an Apple silicon Mac with macOS 26 or later.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var startStep: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Start the engine").font(.largeTitle.weight(.bold))
            Text("The engine is a set of background services that create and run containers. It keeps running when you quit Irekobox.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.m) {
                Button {
                    Task {
                        isStarting = true
                        await app.startServices()
                        isStarting = false
                    }
                } label: {
                    HStack {
                        if isStarting { ProgressView().controlSize(.small) }
                        Text(isStarting ? "Starting…" : "Start Engine")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isStarting)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.start")
            }
            if isStarting {
                Text("The first start downloads the default Linux kernel package (about 700 MB), which can take several minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = app.lastError, !isStarting {
                NoticeBanner(tone: .critical, title: "The engine didn't start", message: error)
            }
        }
    }

    private var backgroundStep: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Ready to go").font(.largeTitle.weight(.bold))
            Label("container \(app.systemStatus?.apiServerVersion ?? "") is running.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Tone.positive.text)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Toggle("Keep watching containers when the window is closed", isOn: $agentEnabled)
                    .accessibilityIdentifier("setup.agent")
                Text("A small background helper keeps container state fresh for the menu bar while the window is closed. macOS lists it under Login Items; you can turn it off there or in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                app.setBackgroundAgentEnabled(agentEnabled)
                app.setupCompleted = true
            } label: {
                Text("Open Irekobox").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("setup.finish")
        }
    }
}
