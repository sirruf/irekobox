import SwiftUI
import ContainerKit

/// The status pill for a container lifecycle state.
struct StatusBadge: View {
    let state: Container.State

    var body: some View {
        StatusPill(tone: Tone(state), label: label)
    }

    private var label: String {
        switch state {
        case .running: return String(localized: "Running")
        case .stopping: return String(localized: "Stopping")
        case .stopped: return String(localized: "Stopped")
        case .unknown(let raw): return raw.capitalized
        }
    }
}
