import SwiftUI
import ContainerKit

/// Shown in every section while the engine is stopped, so nobody wonders
/// where their containers went: they're kept, and Start Engine brings them back.
struct ServiceGateView: View {
    @Environment(AppState.self) private var app
    @State private var isStarting = false
    @AppStorage("lastKnownContainers") private var containers = 0
    @AppStorage("lastKnownMachines") private var machines = 0
    @AppStorage(AppState.stoppedByUserKey) private var stoppedByUser = true
    @AppStorage("lastSeenRunning") private var lastSeenRunning = 0.0

    private var waiting: String {
        let others = containers - machines
        switch (others > 0, machines > 0) {
        case (true, true):
            return String(localized: "Your \(others) containers and \(machines) machines are safe and will come back as they were. Nothing runs until you start it.")
        case (true, false):
            return String(localized: "Your \(others) containers are safe and will come back as they were. Nothing runs until you start it.")
        case (false, true):
            return String(localized: "Your \(machines) machines are safe and will come back as they were. Nothing runs until you start it.")
        case (false, false):
            return String(localized: "Nothing runs until you start it.")
        }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: "power")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The engine is stopped").font(.title.weight(.semibold))
            Text(waiting)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button {
                Task {
                    isStarting = true
                    await app.startServices()
                    isStarting = false
                }
            } label: {
                if isStarting { ProgressView().controlSize(.small) } else { Text("Start Engine") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStarting)
            .accessibilityIdentifier("gate.start")
            Button("Why did it stop?") { openTroubleshoot() }
                .buttonStyle(.link)
            if let error = app.lastError {
                Text(error).font(.callout).foregroundStyle(Tone.critical.text).multilineTextAlignment(.center)
            } else if !stoppedByUser, lastSeenRunning > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last time it stopped unexpectedly").font(.callout.weight(.semibold)).foregroundStyle(Tone.critical.text)
                    HStack(spacing: 4) {
                        Text("It was running at \(Date(timeIntervalSince1970: lastSeenRunning).formatted(date: .omitted, time: .shortened)).")
                        Button("See its last errors") { openTroubleshoot() }.buttonStyle(.link)
                    }
                    .font(.caption)
                }
                .padding(DS.Spacing.m)
                .frame(maxWidth: 460, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(Tone.critical.fill.opacity(0.1)))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openTroubleshoot() {
        UserDefaults.standard.set("Troubleshoot", forKey: "settingsTab")
        app.settingsRequest += 1
    }
}
