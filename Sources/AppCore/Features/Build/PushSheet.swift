import SwiftUI
import ContainerKit

/// Where an image can be pushed, and why not.
enum PushDestination {
    /// The registry host of a reference: its first part when that looks
    /// like a host, else Docker Hub.
    static func registry(of reference: String) -> String {
        let first = reference.split(separator: "/").first.map(String.init) ?? ""
        let isHost = reference.contains("/") && (first.contains(".") || first.contains(":") || first == "localhost")
        return isHost ? first : "docker.io"
    }

    /// "docker.io/library/nginx:alpine" → "nginx:alpine"; else `nil`.
    static func officialName(_ reference: String) -> String? {
        for prefix in ["docker.io/library/", "library/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference.contains("/") ? nil : reference
    }

    /// Where to push `reference` unless told otherwise: the same name, but
    /// an official Docker Hub image goes under the signed-in account (or
    /// needs one).
    static func suggestion(for reference: String, logins: [RegistryLogin]) -> String {
        guard let name = officialName(reference) else { return reference }
        let hub = logins.first { ["docker.io", "registry-1.docker.io", "index.docker.io"].contains($0.hostname) }
        return hub?.username.map { "docker.io/\($0)/\(name)" } ?? ""
    }

    /// What's wrong with pushing to `destination`, if anything.
    static func problem(_ destination: String) -> String? {
        let target = destination.trimmingCharacters(in: .whitespaces)
        if target.isEmpty { return String(localized: "Say where to push it, e.g. docker.io/your-name/app:1.0 or ghcr.io/your-name/app:1.0.") }
        if target.contains(" ") { return String(localized: "An image name has no spaces.") }
        if officialName(target) != nil {
            return String(localized: "Official Docker Hub images belong to Docker. Push under your account: docker.io/your-name/\(officialName(target)!).")
        }
        return nil
    }
}

/// Push an image: what, where to (another name is tagged first), whether
/// you're signed in there; nothing leaves the Mac until Push is pressed.
struct PushSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let reference: String

    @State private var destination = ""
    @State private var logins: [RegistryLogin] = []
    @State private var model: BuildViewModel?
    @State private var tagError: String?

    var body: some View {
        Group {
            if let model {
                BuildProgressView(model: model, onBack: { self.model = nil }, onClose: { dismiss() })
            } else {
                form
            }
        }
        .frame(width: 520)
        .frame(minHeight: 340)
        .task {
            logins = (try? await app.engine.listRegistryLogins()) ?? [] // best-effort: only a suggestion
            if destination.isEmpty { destination = PushDestination.suggestion(for: reference, logins: logins) }
        }
    }

    private var signedIn: RegistryLogin? {
        let registry = PushDestination.registry(of: destination)
        let names = registry == "docker.io" ? ["docker.io", "registry-1.docker.io", "index.docker.io"] : [registry]
        return logins.first { names.contains($0.hostname) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Push Image").font(.title2.weight(.semibold))
            Text("Pushing uploads the image so other computers — or a real cluster — can pull it.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Spacing.m, verticalSpacing: DS.Spacing.m) {
                GridRow {
                    Text("Image").foregroundStyle(.secondary)
                    Text(reference).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text("To").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        TextField("To", text: $destination, prompt: Text("docker.io/your-name/app:1.0"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityIdentifier("pushSheet.destination")
                        if let problem = PushDestination.problem(destination) {
                            Text(problem).font(.callout)
                                .foregroundStyle(destination.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : Tone.warning.text)
                        } else if let login = signedIn {
                            Group {
                                if let user = login.username {
                                    Label("Signed in to \(login.hostname) as \(user)", systemImage: "checkmark.circle.fill")
                                } else {
                                    Label("Signed in to \(login.hostname)", systemImage: "checkmark.circle.fill")
                                }
                            }
                            .font(.callout).foregroundStyle(Tone.positive.text)
                        } else {
                            Label("Not signed in to \(PushDestination.registry(of: destination)) — add it under Settings › Registries",
                                  systemImage: "person.crop.circle.badge.questionmark")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if destination != reference, PushDestination.problem(destination) == nil {
                            Text("It's tagged with this name first; the image itself stays as it is.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let tagError {
                Text(tagError).font(.callout).foregroundStyle(Tone.critical.text)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pushSheet.cancel")
                Spacer()
                Button("Push") { push() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(PushDestination.problem(destination) != nil)
                    .accessibilityIdentifier("pushSheet.push")
            }
        }
        .padding(DS.Spacing.xl)
    }

    private func push() {
        let target = destination.trimmingCharacters(in: .whitespaces)
        tagError = nil
        Task {
            if target != reference {
                do {
                    try await app.engine.tagImage(reference, as: target)
                } catch {
                    tagError = String(localized: "Couldn't tag it as \(target): \(error.localizedDescription)")
                    return
                }
            }
            let vm = BuildViewModel(engine: app.engine)
            model = vm
            await vm.startPush(target)
            await app.model.refresh([.images])
        }
    }
}
