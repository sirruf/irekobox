import SwiftUI
import AppKit
import EngineCore

/// About Irekobox: what it is and whether everything it runs is well —
/// engine, background agent, Docker API — with Check for Updates and
/// Copy System Info for bug reports.
public struct AboutView: View {
    @Environment(AppState.self) private var app
    @State private var socket: DockerSocketStatus?
    @State private var copied = false
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: DS.Spacing.m) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 150, height: 150)
                    .accessibilityHidden(true)
                Text("Your app, in a container, in a small Linux VM, in your Mac. Boxes inside boxes.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 170)

            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Brand.name).font(.system(size: 22, weight: .bold))
                    Text(versionLine).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("about.version")
                }
                Text("A native Mac app for Apple’s `container`: run apps, Compose projects, machines and Kubernetes without Docker Desktop.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: DS.Spacing.s) {
                    statusRow(engineTone, "Engine", engineText)
                    statusRow(agentTone, "Background agent", agentText)
                    statusRow(socketTone, "Docker API", socketText)
                }
                .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.s + 2)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2).fill(DS.subtleFill))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("about.status")
                HStack(spacing: DS.Spacing.s) {
                    if app.appUpdatesAvailable { updateButton }
                    Button(copied ? "Copied" : "Copy System Info") { copySystemInfo() }
                        .accessibilityIdentifier("about.copyInfo")
                }
                // One line where the language allows, two where it doesn't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Spacing.m) { siteLinks; acknowledgementsLink }
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        HStack(spacing: DS.Spacing.m) { siteLinks }
                        acknowledgementsLink
                    }
                }
                .font(.caption)
                .lineLimit(1)
                Text("\(Brand.copyright) · Apache License 2.0 · Not affiliated with Apple or Docker")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 390, alignment: .leading)
        }
        .padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 24)
        .fixedSize()
        .task(id: app.dockerSocketEnabled) { socket = await app.dockerSocketStatus() }
        .task { await app.checkCLIVersion() }
    }

    @ViewBuilder private var siteLinks: some View {
        Link("irekobox.com", destination: Brand.website).fixedSize()
        Link("Source on GitHub", destination: Brand.source).fixedSize()
        Link("Report a Problem", destination: Brand.issues).fixedSize()
    }

    private var acknowledgementsLink: some View {
        Button("Acknowledgements") { openWindow(id: "acknowledgements") }
            .buttonStyle(.link)
            .fixedSize()
            .accessibilityIdentifier("about.acknowledgements")
    }

    private func statusRow(_ tone: Tone, _ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            StatusDot(tone: tone)
            Text(title).font(.callout)
            Spacer(minLength: DS.Spacing.m)
            Text(value).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(value)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Version and updates

    private var versionLine: String {
        let version = String(localized: "Version \(Brand.version) (\(Brand.build))")
        switch app.appUpdater.phase {
        case .checking: return version + " · " + String(localized: "checking for updates…")
        case .available(let appcast): return version + " · " + String(localized: "\(appcast.version) available")
        case .failed: return version + " · " + String(localized: "couldn’t check for updates")
        case .idle, .downloading, .installing: return version
        }
    }

    @ViewBuilder private var updateButton: some View {
        if case .available(let appcast) = app.appUpdater.phase {
            Button("Install \(appcast.version) and Relaunch") { Task { await app.appUpdater.install(appcast) } }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Check for Updates") { Task { await app.appUpdater.checkIfDue(force: true) } }
                .disabled(app.appUpdater.phase == .checking)
        }
    }

    // MARK: - Status

    private var engineTone: Tone {
        if !app.binaryAvailable { return .critical }
        return app.servicesRunning ? .positive : .neutral
    }

    private var engineText: String {
        if !app.binaryAvailable { return String(localized: "container isn’t installed") }
        guard app.servicesRunning else { return String(localized: "Stopped") }
        return app.systemStatus?.apiServerVersion.map { "container \($0)" } ?? String(localized: "Running")
    }

    private var agentTone: Tone {
        if app.model.isAgentBacked { return .positive }
        return app.backgroundAgentEnabled ? .warning : .neutral
    }

    private var agentText: String {
        if app.model.isAgentBacked { return String(localized: "Running") }
        guard app.backgroundAgentEnabled else { return String(localized: "Off") }
        return app.agentStatus.isEmpty ? String(localized: "Starting…") : app.agentStatus
    }

    private var socketTone: Tone {
        guard app.dockerSocketEnabled else { return .neutral }
        guard let socket else { return .inactive }
        return socket.listening ? .positive : .critical
    }

    private var socketText: String {
        guard app.dockerSocketEnabled else { return String(localized: "Off") }
        guard let socket else { return String(localized: "Needs the background agent") }
        guard socket.listening else { return socket.error ?? String(localized: "Not listening") }
        return (socket.socketPath as NSString).abbreviatingWithTildeInPath
    }

    /// One block to paste into an issue: versions and the three statuses.
    private func copySystemInfo() {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let info = """
        \(Brand.name) \(Brand.version) (\(Brand.build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(String(decoding: model.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
        Engine: \(engineText)
        Background agent: \(agentText)
        Docker API: \(socketText)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// The open-source code inside Irekobox, each with its licence; a window
/// of its own, opened from About.
public struct AcknowledgementsView: View {
    @State private var expanded: Set<String> = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("Irekobox is built on these open-source projects. Thank you.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.bottom, DS.Spacing.xs)
                ForEach(Acknowledgement.all) { item in
                    row(item)
                }
            }
            .padding(DS.Spacing.l)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 240, idealHeight: 300)
    }

    private func row(_ item: Acknowledgement) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                if item.text != nil {
                    Button {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded.contains(item.id) ? 90 : 0))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded.contains(item.id) ? "Hide licence" : "Show licence")
                }
                Link(item.name, destination: item.url).font(.callout.weight(.semibold))
                Text("· \(item.licence)").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: DS.Spacing.m)
                Text(item.use).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if let text = item.text, expanded.contains(item.id) {
                Text(text).font(DS.Font.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Spacing.m).padding(.vertical, DS.Spacing.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2).fill(DS.subtleFill))
    }
}
