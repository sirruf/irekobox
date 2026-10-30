import SwiftUI
import EngineCore

/// Tells the user when a list couldn't be refreshed: the last good data stays
/// on screen, marked with when it was fetched, plus the error and a Retry.
struct StaleDataBanner: View {
    @Environment(AppState.self) private var app
    let resource: EngineResource
    @State private var retrying = false

    var body: some View {
        if let error = app.model.snapshot.error(for: resource) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(Tone.warning.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(error.localizedDescription)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button {
                    Task {
                        retrying = true
                        await app.model.refresh([resource])
                        retrying = false
                    }
                } label: {
                    if retrying { ProgressView().controlSize(.small) } else { Text("Retry") }
                }
                .disabled(retrying)
            }
            .padding(10)
            .background(Tone.warning.background, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("staleBanner.\(resource.rawValue)")
        }
    }

    private var title: String {
        guard let updated = app.model.snapshot.updatedAt(for: resource) else {
            return resource.loadFailedTitle
        }
        return resource.refreshFailedTitle(showingDataFrom: updated.formatted(date: .omitted, time: .shortened))
    }
}

extension EngineResource {
    var displayName: String {
        switch self {
        case .system: return String(localized: "service status")
        case .containers: return String(localized: "containers")
        case .images: return String(localized: "images")
        case .volumes: return String(localized: "volumes")
        case .networks: return String(localized: "networks")
        case .diskUsage: return String(localized: "disk usage")
        }
    }

    /// "Couldn't load containers": nothing was fetched yet.
    var loadFailedTitle: String {
        switch self {
        case .system: return String(localized: "Couldn't load service status")
        case .containers: return String(localized: "Couldn't load containers")
        case .images: return String(localized: "Couldn't load images")
        case .volumes: return String(localized: "Couldn't load volumes")
        case .networks: return String(localized: "Couldn't load networks")
        case .diskUsage: return String(localized: "Couldn't load disk usage")
        }
    }

    /// "Couldn't refresh containers": the last good data stays.
    var refreshFailedTitle: String {
        switch self {
        case .system: return String(localized: "Couldn't refresh service status")
        case .containers: return String(localized: "Couldn't refresh containers")
        case .images: return String(localized: "Couldn't refresh images")
        case .volumes: return String(localized: "Couldn't refresh volumes")
        case .networks: return String(localized: "Couldn't refresh networks")
        case .diskUsage: return String(localized: "Couldn't refresh disk usage")
        }
    }

    /// The same, with the time of the data still on screen.
    func refreshFailedTitle(showingDataFrom time: String) -> String {
        switch self {
        case .system: return String(localized: "Couldn't refresh service status — showing data from \(time)")
        case .containers: return String(localized: "Couldn't refresh containers — showing data from \(time)")
        case .images: return String(localized: "Couldn't refresh images — showing data from \(time)")
        case .volumes: return String(localized: "Couldn't refresh volumes — showing data from \(time)")
        case .networks: return String(localized: "Couldn't refresh networks — showing data from \(time)")
        case .diskUsage: return String(localized: "Couldn't refresh disk usage — showing data from \(time)")
        }
    }
}

extension View {
    /// Pin a ``StaleDataBanner`` for `resource` above the content.
    func staleDataBanner(_ resource: EngineResource) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { StaleDataBanner(resource: resource) }
    }
}
