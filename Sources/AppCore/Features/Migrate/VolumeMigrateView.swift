import SwiftUI

/// Copy Docker named-volume data into `container` volumes.
struct VolumeMigrateView: View {
    @Environment(AppState.self) private var app
    @State private var model: VolumeMigrateViewModel?

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .onAppear { if model == nil { model = VolumeMigrateViewModel(cli: app.cli) } }
        .task { await model?.loadVolumes() }
    }

    @ViewBuilder
    private func content(_ model: VolumeMigrateViewModel) -> some View {
        if !model.dockerAvailable {
            ContentUnavailableView("Docker Not Found", systemImage: "xmark.circle",
                description: Text("Install Docker (or start Docker Desktop) to migrate volume data."))
        } else if model.dockerDown {
            DockerDesktopStopped { Task { await model.loadVolumes() } }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        Label("Bind mounts (host folders) need no migration — mount the same host path with `-v`. Only named volumes hold Docker-managed data and are listed below.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        MigrateGroup(title: String(localized: "Docker named volumes")) {
                            if model.volumes.isEmpty && !model.isLoading {
                                Text("No Docker named volumes.").foregroundStyle(.secondary)
                            }
                            ForEach(model.volumes) { volume in
                                row(model, volume)
                            }
                        }
                    }
                    .padding(DS.Spacing.l)
                }

                statusBar(model)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.loadVolumes() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading || model.migrating != nil)
                }
            }
        }
    }

    private func row(_ model: VolumeMigrateViewModel, _ volume: DockerVolume) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).font(.body.weight(.medium))
                Text(volume.mountpoint).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.migrating == volume.name {
                ProgressView().controlSize(.small)
            } else {
                Button("Migrate") { Task { await model.migrate(volume) } }
                    .disabled(model.migrating != nil || !app.servicesRunning)
            }
        }
    }

    @ViewBuilder
    private func statusBar(_ model: VolumeMigrateViewModel) -> some View {
        if model.migrating != nil || model.status != nil || model.error != nil {
            HStack(spacing: 8) {
                if model.error == nil, let status = model.status {
                    Label(status, systemImage: model.migrating != nil ? "externaldrive.badge.timemachine" : "checkmark.circle.fill")
                        .foregroundStyle(model.migrating != nil ? Color.secondary : Tone.positive.text)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
                }
                Spacer()
            }
            .font(.callout).padding(12).background(.bar)
        }
    }
}
