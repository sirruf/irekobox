import SwiftUI
import ContainerKit

/// Shown when the service status itself can't be determined — distinct from
/// "services are stopped", which has its own gate with a Start button.
struct ServiceStatusErrorView: View {
    @Environment(AppState.self) private var app
    let error: EngineError
    @State private var retrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach the engine", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
                .textSelection(.enabled)
        } actions: {
            Button {
                Task {
                    retrying = true
                    await app.refreshSystem()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView().controlSize(.small) } else { Text("Retry") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(retrying)
        }
        .accessibilityIdentifier("serviceStatusError")
    }
}
