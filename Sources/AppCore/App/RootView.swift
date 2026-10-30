import SwiftUI
import ContainerKit

/// Sidebar destinations, grouped by task. Registries and engine settings live
/// in Settings; Migrate sits under Tools. Docker Hub is searched from the
/// Images pull field.
public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case containers = "Containers"
    case compose = "Compose"
    case machines = "Machines"
    case kubernetes = "Kubernetes"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case migrate = "Migrate"

    public var id: String { rawValue }

    /// The name shown in the sidebar, the palette and the View menu
    /// (`rawValue` stays the id for storage and accessibility identifiers).
    var title: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .containers: return String(localized: "Containers")
        case .compose: return String(localized: "Compose")
        case .machines: return String(localized: "Machines")
        case .kubernetes: return String(localized: "Kubernetes")
        case .images: return String(localized: "Images")
        case .volumes: return String(localized: "Volumes")
        case .networks: return String(localized: "Networks")
        case .migrate: return String(localized: "Migrate")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .containers: return "shippingbox"
        case .compose: return "square.stack.3d.up"
        case .machines: return "desktopcomputer"
        case .kubernetes: return "helm"
        case .images: return "photo.stack"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .migrate: return "arrow.right.arrow.left"
        }
    }

    /// ⌘1…⌘8 in sidebar order (Migrate, a tool, has none).
    var shortcut: Character? {
        switch self {
        case .overview: return "1"
        case .containers: return "2"
        case .compose: return "3"
        case .machines: return "4"
        case .kubernetes: return "5"
        case .images: return "6"
        case .volumes: return "7"
        case .networks: return "8"
        case .migrate: return nil
        }
    }

    enum Group: String, CaseIterable {
        case top = ""
        case workloads = "Workloads"
        case buildAndShip = "Build & Ship"
        case resources = "Resources"
        case tools = "Tools"

        var title: String {
            switch self {
            case .top: return ""
            case .workloads: return String(localized: "Workloads")
            case .buildAndShip: return String(localized: "Build & Ship")
            case .resources: return String(localized: "Resources")
            case .tools: return String(localized: "Tools")
            }
        }

        var sections: [SidebarSection] {
            SidebarSection.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .overview: return .top
        case .containers, .compose, .machines, .kubernetes: return .workloads
        case .images: return .buildAndShip
        case .volumes, .networks: return .resources
        case .migrate: return .tools
        }
    }
}

public struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(WelcomeView.shownKey) private var welcomeShown = false

    /// The introduction, once, when the engine is ready (not during UI tests).
    private var showWelcome: Bool {
        !welcomeShown && !needsSetup && app.servicesRunning
            && !ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    public init() {}

    /// First run (or a missing / too old `container`): the setup flow takes
    /// the whole window; there's nothing to navigate yet.
    private var needsSetup: Bool {
        !app.binaryAvailable || !app.cliSupported
            || (!app.setupCompleted && (app.setupInProgress || app.model.snapshot.service == .stopped))
    }

    public var body: some View {
        Group {
            if needsSetup {
                SetupView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                main
            }
        }
        .onChange(of: app.settingsRequest) { openSettings() }
        .engineConfirmation(Binding(get: { app.engineRequest }, set: { app.engineRequest = $0 })) { action in
            Task { await app.perform(action) }
        }
        .onOpenURL { app.open($0) }
        .onChange(of: app.windowRequest) { _, request in
            switch request {
            case .logs(let target): openWindow(id: "logs", value: target)
            case .composeFile(let name): openWindow(id: "compose-file", value: name)
            case nil: return
            }
            app.windowRequest = nil
        }
        .sheet(isPresented: Binding(get: { showWelcome }, set: { if !$0 { welcomeShown = true } })) {
            WelcomeView()
        }
    }

    private var main: some View {
        @Bindable var app = app
        return NavigationSplitView {
            List(selection: Binding(get: { app.section }, set: { if let s = $0 { app.section = s } })) {
                ForEach(SidebarSection.Group.allCases, id: \.self) { group in
                    if group == .top {
                        rows(group.sections)
                    } else {
                        Section(group.title) { rows(group.sections) }
                    }
                }
            }
            .accessibilityIdentifier("sidebar.list")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                EngineFooter()
                    .padding(DS.Spacing.m)
            }
            .task { await app.model.observe([.containers, .images]) }
            // Already up and running (an existing install): nothing to set up.
            .onChange(of: app.servicesRunning, initial: true) { _, running in
                if running && !app.setupInProgress { app.setupCompleted = true }
            }
        } detail: {
            detail
                .id(app.engineGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(DS.accent)
        .sheet(isPresented: $app.showPalette) {
            PaletteView().environment(app)
        }
        .sheet(item: $app.runRequest) { request in
            RunSheet(configuration: request.configuration, paste: request.paste) { name in
                app.section = .containers
                app.revealContainer = name
            }
            .environment(app)
        }
    }

    private func rows(_ sections: [SidebarSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
                .badge(count(for: section))
                .tag(section)
                .accessibilityIdentifier("sidebar.\(section.rawValue)")
        }
    }

    /// Counts shown next to a destination (user objects only).
    private func count(for section: SidebarSection) -> Int {
        guard app.servicesRunning else { return 0 }
        switch section {
        case .containers: return app.model.containers.filter { !$0.isSystem }.count
        case .compose:
            return Set(app.model.containers.filter { !$0.isSystem }.compactMap(ContainerList.project(of:))).count
        case .machines: return app.model.containers.filter(\.isMachine).count
        case .images: return app.model.images.filter { !$0.isSystem }.count
        default: return 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.model.snapshot.service {
        case .unknown:
            ProgressView("Connecting to the engine…")
                .accessibilityIdentifier("serviceConnecting")
        case .stopped:
            ServiceGateView()
        case .failed(let error):
            ServiceStatusErrorView(error: error)
        case .running:
            section
                .errorToast(Binding(get: { app.actionError }, set: { app.actionError = $0 }))
                .overlay(alignment: .bottom) {
                    if let problem = app.problem {
                        ProblemToast(problem: problem) { app.problem = nil }
                            .id(problem.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: app.problem?.id)
        }
    }

    @ViewBuilder
    private var section: some View {
        switch app.section {
        case .overview: DashboardView()
        case .containers: ContainersView()
        case .compose: ComposeView()
        case .machines: MachinesView()
        case .kubernetes: KubernetesView()
        case .images: ImagesView()
        case .volumes: VolumesView()
        case .networks: NetworksView()
        case .migrate: MigrateView()
        }
    }
}

/// Sidebar footer: engine state and version; opens Settings.
private struct EngineFooter: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SettingsLink {
            HStack(spacing: DS.Spacing.s) {
                StatusDot(tone: tone)
                    .background { if tone == .positive { Ping() } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(.background.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Engine settings")
        .accessibilityIdentifier("sidebar.serviceFooter")
    }

    private var tone: Tone {
        switch app.model.snapshot.service {
        case .unknown: return .inactive
        case .running: return .positive
        case .stopped: return .critical
        case .failed: return .warning
        }
    }

    private var title: String {
        switch app.model.snapshot.service {
        case .unknown: return String(localized: "Connecting…")
        case .running: return String(localized: "Engine running")
        case .stopped: return String(localized: "Engine stopped")
        case .failed: return String(localized: "Status unavailable")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = app.systemStatus?.apiServerVersion { parts.append("container \(version)") }
        parts.append(app.model.isAgentBacked ? String(localized: "agent on") : String(localized: "agent off"))
        return parts.joined(separator: " · ")
    }
}

/// A ring that grows out of the engine dot and fades: it's alive.
private struct Ping: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle().fill(Tone.positive.fill)
            .scaleEffect(on ? 2.6 : 1)
            .opacity(on ? 0 : 0.55)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { on = true }
            }
            .accessibilityHidden(true)
    }
}

/// File and View menu commands: Run Container (⌘N), Find Anything (⌘K),
/// and ⌘1…⌘8 for the sidebar sections in their order.
public struct NavigationCommands: Commands {
    let app: AppState

    public init(app: AppState) {
        self.app = app
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Run Container…") { app.requestRun() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!app.servicesRunning)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Anything…") { app.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!app.servicesRunning)
        }
        CommandGroup(before: .sidebar) {
            ForEach(SidebarSection.allCases.filter { $0.shortcut != nil }) { section in
                Button(section.title) { app.section = section }
                    .keyboardShortcut(KeyEquivalent(section.shortcut!), modifiers: .command)
            }
            Divider()
        }
    }
}
