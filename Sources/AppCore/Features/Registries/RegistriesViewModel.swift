import Foundation
import Observation
import ContainerKit

/// Drives the Registries screen: list logins, authenticate (password via stdin),
/// and persist credentials in the Keychain.
@MainActor
@Observable
final class RegistriesViewModel {
    private let engine: any ContainerEngine

    var logins: [RegistryLogin] = []
    var savedServers: Set<String> = []
    var error: String?
    var status: String?
    var isBusy = false

    init(engine: any ContainerEngine) {
        self.engine = engine
    }

    func load() async {
        do {
            logins = try await engine.listRegistryLogins()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        savedServers = Set(KeychainStore.savedServers())
    }

    func login(server: String, username: String, password: String,
               scheme: RegistryScheme, remember: Bool) async {
        guard !server.isEmpty, !username.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await engine.registryLogin(server: server, username: username, password: password, scheme: scheme)
            if remember {
                try KeychainStore.save(server: server,
                                       credentials: RegistryCredentials(username: username, password: password))
            }
            status = String(localized: "Logged in to \(server).")
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
    }

    func logout(_ server: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await engine.registryLogout(server: server)
            KeychainStore.delete(server: server)
            status = String(localized: "Logged out of \(server).")
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Re-authenticate using the Keychain-stored secret (no retyping).
    func reloginFromKeychain(_ server: String) async {
        guard let credentials = KeychainStore.load(server: server) else {
            error = String(localized: "No saved credentials for \(server).")
            return
        }
        await login(server: server, username: credentials.username,
                    password: credentials.password, scheme: .auto, remember: true)
    }

    func isSaved(_ server: String) -> Bool { savedServers.contains(server) }
}
