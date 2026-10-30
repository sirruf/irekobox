import SwiftUI
import ContainerKit

/// The Settings window (⌘,): General, Engine, Docker, AI Assistants, Learning,
/// Registries, Troubleshoot.
public struct SettingsView: View {
    public init() {}
    /// Reopens on the tab used last.
    @AppStorage("settingsTab") private var tab = "General"

    public var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .tag("General")
                .tabItem { Label("General", systemImage: "gearshape") }
            EngineSettingsPane()
                .frame(width: 560, height: 520)
                .tag("Engine")
                .tabItem { Label("Engine", systemImage: "shippingbox") }
            DockerCompatibilityPane()
                .frame(width: 560, height: 420)
                .tag("Docker")
                .tabItem { Label("Docker", systemImage: "arrow.left.arrow.right") }
            AssistantsPane()
                .frame(width: 620, height: 560)
                .tag("AI Assistants")
                .tabItem { Label("AI Assistants", systemImage: "bubble.left.and.text.bubble.right") }
            LearningPane()
                .frame(width: 520, height: 300)
                .tag("Learning")
                .tabItem { Label("Learning", systemImage: "graduationcap") }
            RegistriesView()
                .frame(width: 560, height: 420)
                .tag("Registries")
                .tabItem { Label("Registries", systemImage: "lock.shield") }
            TroubleshootPane()
                .frame(width: 640, height: 520)
                .tag("Troubleshoot")
                .tabItem { Label("Troubleshoot", systemImage: "stethoscope") }
        }
        .tint(DS.accent)
    }
}

/// Settings › General: background agent, `container` binary path, polling.
struct GeneralSettingsPane: View {
    @Environment(AppState.self) private var app
    @State private var settings = Settings.shared
    @State private var pathExists = true
    /// Draft of the binary path. The persisted setting (and the rebuilt CLI
    /// client) is only updated on Apply/Reset, so a half-typed path can't be
    /// saved or take effect on the next launch.
    @State private var pathDraft = Settings.shared.binaryPath
    @AppStorage("notifyCrashes") private var notifyCrashes = true
    @AppStorage("notifyHealth") private var notifyHealth = true


    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    BrandLogo(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Brand.name).font(.headline)
                        Text("Version \(Brand.version) · \(Brand.tagline)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Section("Background") {
                Toggle("Keep running in the background",
                       isOn: Binding(get: { app.backgroundAgentEnabled },
                                     set: { app.setBackgroundAgentEnabled($0) }))
                    .accessibilityIdentifier("settings.backgroundAgent")
                Text(app.agentStatus.isEmpty ? String(localized: "Starting…") : app.agentStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Check for container updates",
                       isOn: Binding(get: { app.updates.isEnabled }, set: { app.updates.isEnabled = $0 }))
                Text("Once a day, the latest apple/container release is looked up on GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if app.appUpdatesAvailable {
                AppUpdateSection(updater: app.appUpdater)
            }

            Section("Notifications") {
                Toggle("When a service crashes", isOn: $notifyCrashes)
                    .accessibilityIdentifier("settings.notifyCrashes")
                Toggle("When a health check fails or recovers", isOn: $notifyHealth)
                    .accessibilityIdentifier("settings.notifyHealth")
                Toggle("When a newer image is published", isOn: Binding(
                    get: { app.imageUpdates.isEnabled }, set: { app.imageUpdates.isEnabled = $0 }))
                    .accessibilityIdentifier("settings.notifyImages")
                Text(app.backgroundAgentEnabled
                     ? "Services are containers with a restart policy or from a compose project; stopping one yourself isn't a crash. Shown while Irekobox runs (its menu bar icon is enough)."
                     : "Needs the background helper above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!app.backgroundAgentEnabled)

            Section("Container CLI") {
                TextField("Binary path", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.binaryPath")
                .onSubmit { apply() }

                HStack {
                    if pathExists {
                        Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.positive.text)
                    } else {
                        Label("Not executable at this path", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Tone.warning.text)
                    }
                    Spacer()
                    Button("Reset") { pathDraft = ContainerCLI.defaultBinaryPath; apply() }
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.apply")
                        .disabled(pathDraft == settings.binaryPath)
                }
                .font(.caption)
            }

            Section("Refresh") {
                HStack {
                    Slider(value: Binding(get: { settings.pollingInterval },
                                          set: { settings.pollingInterval = $0; app.applyPollingInterval() }),
                           in: 1...30, step: 1)
                    Text("\(Int(settings.pollingInterval))s").monospacedDigit().frame(width: 36)
                }
                Text("How often the container list refreshes while visible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .frame(width: 520, height: 400)
        // `.contain` keeps the ids of the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.form")
        .onAppear { validate() }
        .onChange(of: pathDraft) { validate() }
    }

    private func validate() {
        pathExists = FileManager.default.isExecutableFile(atPath: pathDraft)
    }

    private func apply() {
        settings.binaryPath = pathDraft
        validate()
        app.reconfigure()
        Task { await app.refreshSystem() }
    }
}

/// Irekobox's own updates (Settings › General).
private struct AppUpdateSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section("Irekobox updates") {
            Toggle("Check daily", isOn: $updater.isEnabled)
            switch updater.phase {
            case .idle:
                LabeledContent("Version \(Brand.version)") {
                    Button("Check Now") { Task { await updater.checkIfDue(force: true) } }
                }
            case .checking:
                LabeledContent("Checking…") { ProgressView().controlSize(.small) }
            case .available(let appcast):
                LabeledContent("Version \(appcast.version) is available") {
                    Button("Install and Relaunch") { Task { await updater.install(appcast) } }
                        .buttonStyle(.borderedProminent)
                }
                if let notes = appcast.notes {
                    Text(notes).font(.caption).foregroundStyle(.secondary)
                }
            case .downloading:
                LabeledContent("Downloading…") { ProgressView().controlSize(.small) }
            case .installing:
                LabeledContent("Installing…") { ProgressView().controlSize(.small) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
                Button("Try Again") { Task { await updater.checkIfDue(force: true) } }
            }
        }
    }
}

/// Settings › Learning: how much the app explains as you go.
struct LearningPane: View {
    @AppStorage("firstStepsHidden") private var firstStepsHidden = false
    @AppStorage(LearningSettings.showNotes) private var showNotes = true
    @AppStorage(LearningSettings.explainTerms) private var explainTerms = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { !firstStepsHidden }, set: { firstStepsHidden = !$0 })) {
                    Text("Show First Steps on the Overview")
                    Text("Five things to try, ticked off as you do them.")
                }
                Toggle(isOn: $showNotes) {
                    Text("Explain each screen")
                    Text("The blue notes saying what a screen is about and how its parts fit.")
                }
                Toggle(isOn: $explainTerms) {
                    Text("Explain terms")
                    Text("An ⓘ beside words such as Service, Namespace or Volume.")
                }
            } footer: {
                Text("Turn these off once you know your way around; nothing else changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
