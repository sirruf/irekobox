import SwiftUI

/// Import a local Docker image into `container` (`docker save` → `image load`).
struct DockerImportView: View {
    @Environment(AppState.self) private var app
    @State private var model: DockerImportViewModel?

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .onAppear { if model == nil { model = DockerImportViewModel(cli: app.cli) } }
        .task { await model?.loadImages() }
    }

    @ViewBuilder
    private func content(_ model: DockerImportViewModel) -> some View {
        if !model.dockerAvailable {
            ContentUnavailableView(
                "Docker Not Found",
                systemImage: "xmark.circle",
                description: Text("Install Docker (or start Docker Desktop) to import images. Looked in the usual locations."))
        } else if model.dockerDown {
            DockerDesktopStopped { Task { await model.loadImages() } }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    MigrateGroup(title: String(localized: "Local Docker images")) {
                        if model.images.isEmpty && !model.isLoadingImages {
                            Text("No Docker images found.").foregroundStyle(.secondary)
                        }
                        ForEach(model.images) { image in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(image.reference).font(.body.weight(.medium))
                                    Text(verbatim: "\(image.id) · \(image.size)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Import") {
                                    Task { await model.importImage(image.reference) }
                                }
                                .disabled(model.isImporting)
                            }
                        }
                    }
                    .padding(DS.Spacing.l)
                }

                statusBar(model)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.loadImages() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isLoadingImages || model.isImporting)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBar(_ model: DockerImportViewModel) -> some View {
        if model.isImporting || model.status != nil || model.error != nil {
            HStack(spacing: 8) {
                if model.isImporting { ProgressView().controlSize(.small) }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
                } else if let status = model.status {
                    Label(status, systemImage: model.isImporting ? "shippingbox" : "checkmark.circle.fill")
                        .foregroundStyle(model.isImporting ? Color.secondary : Tone.positive.text)
                }
                Spacer()
            }
            .font(.callout)
            .padding(12)
            .background(.bar)
        }
    }
}
