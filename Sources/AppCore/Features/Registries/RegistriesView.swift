import SwiftUI
import ContainerKit

/// Manage registry logins. Authenticated logins send the password via stdin and
/// optionally persist credentials in the Keychain; public registries need none.
struct RegistriesView: View {
    @Environment(AppState.self) private var app
    @State private var model: RegistriesViewModel?

    // Add-login form
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var scheme: RegistryScheme = .auto
    @State private var remember = true

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .navigationTitle("Registries")
        .onAppear { if model == nil { model = RegistriesViewModel(engine: app.engine) } }
        .task { await model?.load() }
        .task(id: app.refreshTick) { await model?.load() }
    }

    private func content(_ model: RegistriesViewModel) -> some View {
        Form {
            Section("Logins") {
                if model.logins.isEmpty {
                    Text("No registry logins. Public registries (e.g. docker.io) need no login — just pull.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(model.logins) { login in
                        loginRow(model, login)
                    }
                }
            }

            Section("Add login") {
                TextField("Server", text: $server, prompt: Text("registry.example.com"))
                    .accessibilityIdentifier("registries.server")
                TextField("Username", text: $username)
                    .accessibilityIdentifier("registries.username")
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("registries.password")
                Picker("Scheme", selection: $scheme) {
                    ForEach(RegistryScheme.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                Toggle("Remember in Keychain", isOn: $remember)
                HStack {
                    Spacer()
                    Button {
                        Task {
                            await model.login(server: server, username: username,
                                              password: password, scheme: scheme, remember: remember)
                            if model.error == nil { password = "" }
                        }
                    } label: {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        else { Label("Log In", systemImage: "person.badge.key") }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("registries.login")
                    .disabled(model.isBusy || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }

            if let status = model.status {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.positive.text)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Tone.critical.text)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("registries.form")
    }

    private func loginRow(_ model: RegistriesViewModel, _ login: RegistryLogin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(login.hostname).font(.body.weight(.medium))
                if let user = login.username {
                    Text(user).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.isSaved(login.hostname) {
                Text("Saved").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Tone.positive.background))
                    .foregroundStyle(Tone.positive.text)
            }
            Spacer()
            if model.isSaved(login.hostname) {
                Button("Log In Again") { Task { await model.reloginFromKeychain(login.hostname) } }
                    .buttonStyle(.borderless)
            }
            Button(role: .destructive) {
                Task { await model.logout(login.hostname) }
            } label: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                .buttonStyle(.borderless)
                .help("Log out and remove saved credentials")
        }
        .disabled(model.isBusy)
    }
}
