import SwiftUI
import Observation
import ContainerKit

@MainActor
@Observable
final class NetworksViewModel {
    private let engine: any ContainerEngine
    private let model: EngineModel
    var error: String?
    var busy: Set<String> = []
    var newName = ""
    var newSubnet = ""

    var networks: [Network] { model.networks }

    /// Containers attached to `network`.
    func usedBy(_ network: Network) -> [String] {
        members(of: network).map(\.id)
    }

    func members(of network: Network) -> [Container] {
        model.containers.filter { $0.configuration.networks.contains { $0.network == network.name } }
            .sorted { $0.id < $1.id }
    }

    /// A subnet no network uses yet, to suggest for a new one.
    var freeSubnet: String { Subnets.free(after: networks.compactMap(\.subnet)) }
    var isLoading: Bool { model.isLoading(.networks) }

    init(engine: any ContainerEngine, model: EngineModel) {
        self.engine = engine
        self.model = model
    }

    func load() async {
        await model.refresh([.networks])
        error = model.errorMessage(.networks)
    }

    /// `true` once created.
    @discardableResult
    func create() async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        defer { Task { await model.refresh([.networks]) } }
        do {
            try await engine.createNetwork(name, subnet: newSubnet.trimmingCharacters(in: .whitespaces))
            newName = ""; newSubnet = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(_ network: Network) async { await delete([network]) }

    /// Delete each; the first failure is shown, the rest still go.
    func delete(_ networks: [Network]) async {
        let ids = Set(networks.map(\.id))
        busy.formUnion(ids); defer { busy.subtract(ids) }
        for network in networks {
            do { try await engine.deleteNetwork(network.name) }
            catch { if self.error == nil { self.error = error.localizedDescription } }
        }
        await model.refresh([.networks])
    }

    func prune() async {
        do { try await engine.pruneNetworks() }
        catch { self.error = error.localizedDescription }
        await model.refresh([.networks])
    }
}

struct NetworksView: View {
    @Environment(AppState.self) private var app
    @State private var model: NetworksViewModel?
    @State private var confirmPrune = false
    @State private var pendingDelete: Network?
    @State private var selection = CardSelection()
    /// Several selected networks to delete, once confirmed.
    @State private var pendingDeletes: [Network] = []
    @State private var creating = false

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .navigationTitle("Networks")
        .navigationSubtitle("Who can talk to whom")
        .confirmationDialog("Remove all unused networks?", isPresented: $confirmPrune, titleVisibility: .visible) {
            Button("Remove Unused", role: .destructive) { Task { await model?.prune() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingDelete.map { String(localized: "Delete network “\($0.name)”?") } ?? "",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { network in
            Button("Delete", role: .destructive) {
                Task { await model?.delete(network) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            let users = pendingDelete.map { model?.usedBy($0) ?? [] } ?? []
            Text(users.isEmpty
                 ? "No container uses it."
                 : "Attached: \(users.joined(separator: ", ")). They lose this network.")
        }
        .confirmationDialog(String(localized: "Delete \(pendingDeletes.count) networks?"),
                            isPresented: Binding(get: { !pendingDeletes.isEmpty }, set: { if !$0 { pendingDeletes = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let networks = pendingDeletes
                pendingDeletes = []
                selection.clear()
                Task { await model?.delete(networks) }
            }
            Button("Cancel", role: .cancel) { pendingDeletes = [] }
        } message: {
            let users = pendingDeletes.flatMap { model?.usedBy($0) ?? [] }
            Text(users.isEmpty
                 ? "No container uses them."
                 : "Attached: \(users.joined(separator: ", ")). They lose these networks.")
        }
        .sheet(isPresented: $creating) {
            if let model { NewNetworkSheet(model: model) }
        }
        .onAppear { if model == nil { model = NetworksViewModel(engine: app.engine, model: app.model) } }
        .task { await app.model.observe([.networks, .containers]) }
    }

    /// Fixed order by name, never by rank; the name is always shown beside it.
    private static let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .brown, .indigo]

    private func color(_ network: Network, in all: [Network]) -> Color {
        guard !network.isBuiltin else { return .gray }
        let named = all.filter { !$0.isBuiltin }.map(\.name).sorted()
        return Self.colors[(named.firstIndex(of: network.name) ?? 0) % Self.colors.count]
    }

    private func sorted(_ model: NetworksViewModel) -> [Network] {
        model.networks.sorted { ($0.isBuiltin ? 0 : 1, $0.name) < ($1.isBuiltin ? 0 : 1, $1.name) }
    }

    /// One network asks by name; several, by count.
    private func askToDelete(_ model: NetworksViewModel) {
        let chosen = model.networks.filter { selection.contains($0.id) && !$0.isBuiltin }
        if chosen.count == 1 { pendingDelete = chosen[0] } else if !chosen.isEmpty { pendingDeletes = chosen }
    }

    private func content(_ model: NetworksViewModel) -> some View {
        let order = sorted(model).filter { !$0.isBuiltin }.map(\.id)
        return SelectionScroll(selection: $selection, all: order, onDelete: { askToDelete(model) }) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                LearnNote("**Things on the same network see each other by name.** A web app reaches `api:3000` when both are on one network; things on different networks can't — that's how a database stays private.")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top),
                                    GridItem(.flexible(), spacing: DS.Spacing.l, alignment: .top)],
                          spacing: DS.Spacing.l) {
                    ForEach(sorted(model)) { network in
                        if network.isBuiltin {
                            card(network, model)
                        } else {
                            card(network, model)
                                .selectableCard(network.id, in: $selection, order: order, cornerRadius: DS.Radius.panel)
                        }
                    }
                }
                .accessibilityIdentifier("networks.list")
                if model.networks.isEmpty && !model.isLoading {
                    Text("No networks.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("networks.emptyState")
                }
            }
            .padding(DS.Spacing.l)
        }
        .background(DS.canvas)
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                SelectionBar(count: selection.count, onClear: { selection.clear() }) {
                    Button("Delete", role: .destructive) { askToDelete(model) }
                }
            }
        }
        .staleDataBanner(.networks)
        .errorToast(Binding(get: { model.error }, set: { model.error = $0 }))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Remove Unused") { confirmPrune = true }
                    .help("Remove networks nothing is connected to")
                    .accessibilityIdentifier("networks.prune")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("New Network…") { creating = true }
                    .buttonStyle(.borderedProminent)
                    .help("Create a network")
                    .accessibilityIdentifier("networks.new")
            }
        }
    }

    private func card(_ network: Network, _ model: NetworksViewModel) -> some View {
        let members = model.members(of: network)
        let tint = color(network, in: model.networks)
        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(spacing: DS.Spacing.s) {
                Text(network.name).font(.system(.headline, design: .monospaced)).lineLimit(1)
                if network.isBuiltin {
                    Text("built-in").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                        .help("Containers join it unless told otherwise; it can't be deleted")
                }
                Spacer(minLength: DS.Spacing.s)
                Text(network.subnet ?? "").font(DS.Font.monoSmall).foregroundStyle(.secondary)
                    .help(network.gateway.map { String(localized: "Gateway \($0)") } ?? "")
                if model.busy.contains(network.id) {
                    ProgressView().controlSize(.small)
                } else if !network.isBuiltin {
                    Button(role: .destructive) { pendingDelete = network } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(members.isEmpty ? "Delete" : "Delete — its containers lose this network")
                        .accessibilityLabel("Delete network \(network.name)")
                }
            }
            Group {
            if members.isEmpty {
                Text("Nothing connected").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowRow(spacing: DS.Spacing.xs) {
                    ForEach(members, id: \.id) { container in
                        Button { app.openContainer(container.id) } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                StatusDot(tone: container.state.isRunning ? .positive : .inactive, size: 6)
                                Text(memberName(container)).font(.callout)
                            }
                            .padding(.horizontal, DS.Spacing.s + 2).padding(.vertical, 4)
                            .background(Capsule().fill(DS.raised))
                            .hairline(Capsule(), DS.separator.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(container.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            .padding(DS.Spacing.s + 2)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control + 2).fill(DS.subtleFill))
        }
        .panel()
        // The network's colour as a band down its left edge.
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: DS.Radius.panel, bottomLeadingRadius: DS.Radius.panel)
                .fill(tint)
                .frame(width: 4)
        }
        .opacity(members.isEmpty && !network.isBuiltin ? 0.8 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(network.name), \(members.count) connected")
        .contextMenu {
            if selection.contains(network.id) && selection.count > 1 {
                Button("Delete \(selection.count) Networks", role: .destructive) { askToDelete(model) }
            } else if !network.isBuiltin {
                Button("Delete", role: .destructive) { pendingDelete = network }
            }
        }
    }

    /// "web · shop", "test1 · machine", or the container's name.
    private func memberName(_ container: Container) -> String {
        if container.isMachine { return String(localized: "\(container.machineName ?? container.id) · machine") }
        if let project = ContainerList.project(of: container) { return "\(container.serviceName) · \(project)" }
        return container.id
    }
}

/// Name and subnet for a new network, with a free subnet suggested.
private struct NewNetworkSheet: View {
    let model: NetworksViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private var subnetProblem: String? {
        let subnet = model.newSubnet.trimmingCharacters(in: .whitespaces)
        guard !subnet.isEmpty else { return nil }
        guard let range = Subnets.range(subnet) else { return String(localized: "Write it as four numbers and a size, like 10.10.0.0/24.") }
        if let taken = model.networks.first(where: { $0.subnet.flatMap(Subnets.range).map { $0.overlaps(range) } ?? false }) {
            return String(localized: "Overlaps \(taken.name) (\(taken.subnet ?? "")).")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("New Network").font(.title2.weight(.semibold))
            Text("Containers you put on it reach each other by name, and nothing else on this Mac sees them unless a port is published.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: Binding(get: { model.newName }, set: { model.newName = $0 }), prompt: Text("e.g. shop_back"))
                    .accessibilityIdentifier("networks.nameField")
                TextField("Subnet", text: Binding(get: { model.newSubnet }, set: { model.newSubnet = $0 }),
                          prompt: Text(model.freeSubnet))
                    .accessibilityIdentifier("networks.subnetField")
                if let subnetProblem {
                    Text(subnetProblem).font(.callout).foregroundStyle(Tone.critical.text)
                } else {
                    Text("Leave it empty to get a free one (\(model.freeSubnet) is free).").font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        working = true
                        if await model.create() { dismiss() }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.newName.trimmingCharacters(in: .whitespaces).isEmpty || subnetProblem != nil || working)
                .accessibilityIdentifier("networks.create")
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 460)
    }
}

/// IPv4 subnets in CIDR form.
enum Subnets {
    struct Range: Equatable {
        let start: UInt32
        let end: UInt32
        func overlaps(_ other: Range) -> Bool { start <= other.end && other.start <= end }
    }

    static func range(_ cidr: String) -> Range? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (8...30).contains(prefix) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        let address = octets.reduce(0) { $0 << 8 | $1 }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        let start = address & mask
        return Range(start: start, end: start | ~mask)
    }

    /// The first 192.168.N.0/24 above the ones in use (from 64, where
    /// `container` starts) that overlaps none of them: below the highest
    /// may be something `container` hands out on its own.
    static func free(after used: [String]) -> String {
        let taken = used.compactMap(range)
        let highest = taken.filter { $0.start >> 16 == 0xC0A8 }.map { Int(($0.end >> 8) & 0xFF) }.max() ?? 63
        for third in max(64, highest + 1)...254 {
            let candidate = "192.168.\(third).0/24"
            if let range = range(candidate), !taken.contains(where: { $0.overlaps(range) }) { return candidate }
        }
        return "10.10.0.0/24"
    }
}
