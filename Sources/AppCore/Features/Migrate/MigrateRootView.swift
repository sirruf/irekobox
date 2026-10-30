import SwiftUI

/// "Migrate from Docker" hub: move a whole Docker Desktop setup, translate a
/// `docker run` command, or import single images and volumes.
struct MigrateView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case desktop = "Docker Desktop"
        case dockerRun = "docker run"
        case importImage = "Import image"
        case volumes = "Volumes"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .desktop: return "Docker Desktop"
            case .dockerRun: return "docker run"
            case .importImage: return String(localized: "Import image")
            case .volumes: return String(localized: "Volumes")
            }
        }
    }

    @State private var mode: Mode = .desktop

    var body: some View {
        Group {
            switch mode {
            case .desktop: DesktopMigrationView()
            case .dockerRun: DockerRunTranslateView()
            case .importImage: DockerImportView()
            case .volumes: VolumeMigrateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.canvas)
        .navigationTitle("Migrate from Docker")
        .navigationSubtitle("Bring containers, images and volumes over from Docker")
        .toolbar {
            // Switching what the window shows: centred, as macOS places view switchers.
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("migrate.modePicker")
            }
        }
    }
}

/// A titled group of rows on Migrate's canvas: the header above a raised
/// panel, rows divided by hairlines, an optional note below.
struct MigrateGroup<Rows: View>: View {
    let title: String
    var note: LocalizedStringKey?
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: rows) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        if index > 0 { Divider() }
                        subviews[index].padding(.vertical, DS.Spacing.s)
                    }
                }
            }
            .panel(padding: DS.Spacing.l)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Docker Desktop is installed but stopped: nothing to read until it starts.
struct DockerDesktopStopped: View {
    let checkAgain: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Docker Desktop isn't running", systemImage: "moon.zzz")
        } description: {
            Text("Start Docker Desktop so its containers, images and volumes can be read. Nothing in it is changed until you choose to move.")
        } actions: {
            Button("Check Again", action: checkAgain)
        }
    }
}
