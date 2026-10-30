import Foundation
import Observation
import ContainerKit
import EngineCore

/// Main-actor mirror of the engine state for SwiftUI: the latest snapshot and
/// events, plus `observe(_:)` for screens to declare what they show.
///
/// The source is swappable — the in-process ``EngineStore`` at launch, the
/// background agent once it is connected, and back if the agent goes away.
/// Active interests and window visibility move to the new source.
@MainActor
@Observable
public final class EngineModel {
    private(set) var snapshot = EngineSnapshot()
    /// Events from the most recent update.
    private(set) var lastEvents: [EngineEvent] = []
    /// `true` while state comes from the background agent.
    private(set) var isAgentBacked = false
    /// What changed since the app opened, newest first.
    private(set) var activity: [ActivityEntry] = []

    @ObservationIgnored private(set) var source: any EngineStateSource
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// Screen interest id → resources and the current source's token.
    @ObservationIgnored private var interests: [UUID: (resources: Set<EngineResource>, token: UUID?)] = [:]
    @ObservationIgnored private var visible = true
    /// Told the events of each update that has any (the alert notifier
    /// polls at once when a container changed).
    @ObservationIgnored var onEvents: (([EngineEvent]) -> Void)?

    init(source: any EngineStateSource) {
        self.source = source
        consume(source)
    }

    /// Switch to another source, carrying interests and visibility over.
    func setSource(_ newSource: any EngineStateSource, agentBacked: Bool) async {
        let old = source
        guard old !== newSource else { return }
        source = newSource
        isAgentBacked = agentBacked
        consume(newSource)
        await newSource.setVisible(visible)
        for (id, interest) in interests {
            let token = await newSource.addInterest(interest.resources)
            if interests[id] != nil { interests[id]?.token = token } else { await newSource.removeInterest(token) }
            if let oldToken = interest.token { await old.removeInterest(oldToken) }
        }
    }

    private func consume(_ source: any EngineStateSource) {
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await update in await source.updates() {
                guard let self, !Task.isCancelled, self.source === source else { return }
                let old = self.snapshot
                self.snapshot = update.snapshot
                self.lastEvents = update.events
                self.record(update.events.compactMap { ActivityEntry.make($0, old: old, new: update.snapshot) })
                if !update.events.isEmpty { self.onEvents?(update.events) }
            }
        }
    }

    /// Add entries to the activity, newest first, keeping the last 50.
    func record(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        activity = Array((entries.reversed() + activity).prefix(50))
    }

    // MARK: - Convenience

    var containers: [Container] { snapshot.containers.value ?? [] }
    var images: [ContainerImage] { snapshot.images.value ?? [] }
    var volumes: [Volume] { snapshot.volumes.value ?? [] }
    var networks: [Network] { snapshot.networks.value ?? [] }

    /// `true` until the first successful load of `resource`.
    func isLoading(_ resource: EngineResource) -> Bool {
        switch resource {
        case .system: return snapshot.service == .unknown
        case .containers: return snapshot.containers.updatedAt == nil && snapshot.containers.error == nil
        case .images: return snapshot.images.updatedAt == nil && snapshot.images.error == nil
        case .volumes: return snapshot.volumes.updatedAt == nil && snapshot.volumes.error == nil
        case .networks: return snapshot.networks.updatedAt == nil && snapshot.networks.error == nil
        case .diskUsage: return snapshot.diskUsage.updatedAt == nil && snapshot.diskUsage.error == nil
        }
    }

    // MARK: - Interest

    /// Keep `resources` fresh for as long as the calling task lives — use from
    /// a SwiftUI `.task`; leaving the screen cancels it and ends the interest.
    func observe(_ resources: Set<EngineResource>) async {
        let id = UUID()
        interests[id] = (resources, nil)
        let source = self.source
        let token = await source.addInterest(resources)
        if interests[id] != nil, self.source === source {
            interests[id]?.token = token
        } else {
            await source.removeInterest(token)
        }
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        } onCancel: {
            Task { @MainActor [weak self] in await self?.endInterest(id) }
        }
    }

    private func endInterest(_ id: UUID) async {
        guard let interest = interests.removeValue(forKey: id), let token = interest.token else { return }
        await source.removeInterest(token)
    }

    /// Fetch now; returns with data fetched after the call (use after a mutation).
    /// Resources other than `.system` need running services, so an unknown
    /// service state is resolved first.
    func refresh(_ resources: Set<EngineResource>) async {
        var resources = resources
        if snapshot.service == .unknown { resources.insert(.system) }
        snapshot = await source.refreshSnapshot(resources)
    }

    func setVisible(_ visible: Bool) async {
        self.visible = visible
        await source.setVisible(visible)
    }

    func polledResources() async -> Set<EngineResource> {
        await source.currentlyPolled()
    }

    /// The latest fetch error for `resource`, for display.
    func errorMessage(_ resource: EngineResource) -> String? {
        snapshot.error(for: resource)?.localizedDescription
    }
}
