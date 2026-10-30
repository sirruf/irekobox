import SwiftUI

/// Stopping or restarting the engine stops every running container, so
/// every place that offers either asks first.
enum EngineAction: Identifiable {
    case stop, restart
    var id: Self { self }
}

extension View {
    /// Asks before `action` runs; `perform` gets the confirmed action.
    func engineConfirmation(_ action: Binding<EngineAction?>,
                            perform: @escaping (EngineAction) -> Void) -> some View {
        confirmationDialog(action.wrappedValue == .restart ? "Restart the engine?" : "Stop the engine?",
                           isPresented: Binding(get: { action.wrappedValue != nil },
                                                set: { if !$0 { action.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: action.wrappedValue) { request in
            switch request {
            case .stop: Button("Stop Engine", role: .destructive) { perform(.stop) }
            case .restart: Button("Restart Engine", role: .destructive) { perform(.restart) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            switch request {
            case .stop: Text("Running containers stop until the engine is started again.")
            case .restart: Text("Running containers stop while the engine restarts.")
            }
        }
    }
}
