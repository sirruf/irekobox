import SwiftUI
import Observation
import ContainerKit

/// Completions for an image field: images on this Mac and Docker Hub
/// repositories for a name, the repository's tags after a colon.
@MainActor
@Observable
final class ImageSuggester {
    private(set) var suggestions: [PullSuggestion] = []
    private(set) var note: String?
    /// Characters typed before anything is offered.
    var minimumLength = 2
    private var task: Task<Void, Never>?
    private var tagCache: [String: [String]] = [:]
    private let registry: RegistryClient
    private let search: @Sendable (String, Int) async throws -> [SearchResult]

    init(search: @escaping @Sendable (String, Int) async throws -> [SearchResult] = DockerHubSearch.search,
         registry: RegistryClient = RegistryClient()) {
        self.search = search
        self.registry = registry
    }

    /// Offers only `repositories` (matched by name, no Docker Hub search),
    /// then their tags.
    convenience init(only repositories: [SearchResult], registry: RegistryClient = RegistryClient()) {
        self.init(search: { term, limit in
            let term = term.lowercased()
            return Array(repositories.filter { $0.name.contains(term) || $0.description.lowercased().contains(term) }
                .prefix(limit))
        }, registry: registry)
    }

    /// Refresh `suggestions` for what's typed, after a short pause.
    /// `local` are references on this Mac, offered first when they match.
    func suggest(_ typed: String, local: [String] = []) {
        task?.cancel()
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count >= minimumLength else {
            clear()
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.load(for: text, local: local)
        }
    }

    func clear() {
        task?.cancel()
        suggestions = []
        note = nil
    }

    func load(for text: String, local: [String] = []) async {
        let query = text.lowercased()
        let onThisMac = local.filter { $0.lowercased().contains(query) && $0.lowercased() != query }
            .prefix(5).map { PullSuggestion.local($0) }
        do {
            if let colon = text.lastIndex(of: ":"), !text[colon...].contains("/") {
                let name = String(text[..<colon])
                let typed = String(text[text.index(after: colon)...]).lowercased()
                guard let reference = ImageReference(name) else { suggestions = onThisMac; return }
                let tags = try await tags(of: reference)
                guard !Task.isCancelled else { return }
                let matching = tags.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
                suggestions = onThisMac + matching.prefix(40).map { .tag(name: name, tag: $0) }
                note = matching.count > 40 ? String(localized: "\(matching.count) tags; type more to narrow") : nil
            } else {
                let results = try await search(text, 15)
                guard !Task.isCancelled else { return }
                suggestions = onThisMac + results.map { .repository($0) }
                note = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            suggestions = onThisMac
            note = error.localizedDescription
        }
    }

    private func tags(of reference: ImageReference) async throws -> [String] {
        let key = "\(reference.registry)/\(reference.repository)"
        if let cached = tagCache[key] { return cached }
        let tags = try await registry.tags(registry: reference.registry, repository: reference.repository,
                                           credentials: Self.credentials(for: reference.registry))
        tagCache[key] = tags
        return tags
    }

    /// The saved login for `registry`, Docker Hub under any of its names.
    static func credentials(for registry: String) -> RegistryClient.Credentials? {
        let names = registry == "docker.io"
            ? ["docker.io", "registry-1.docker.io", "index.docker.io", "hub.docker.com"]
            : [registry]
        for name in names {
            if let saved = KeychainStore.load(server: name) {
                return .init(username: saved.username, password: saved.password)
            }
        }
        return nil
    }
}

/// One row under an image field.
enum PullSuggestion: Hashable, Identifiable {
    case local(String)
    case repository(SearchResult)
    case tag(name: String, tag: String)

    var id: String { completion }

    /// What the field becomes: a repository goes on to its tags.
    var completion: String {
        switch self {
        case .local(let reference): return reference
        case .repository(let result): return result.name + ":"
        case .tag(let name, let tag): return "\(name):\(tag)"
        }
    }
}

extension View {
    /// The suggester's completions under this text field.
    func imageSuggestions(_ suggester: ImageSuggester) -> some View {
        textInputSuggestions {
            ForEach(suggester.suggestions) { ImageSuggestionRow(suggestion: $0).textInputCompletion($0.completion) }
        }
    }
}

struct ImageSuggestionRow: View {
    let suggestion: PullSuggestion

    var body: some View {
        switch suggestion {
        case .local(let reference):
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    .accessibilityLabel("On this Mac")
                Text(reference).fontWeight(.medium)
                Spacer()
                Text("On this Mac").font(.caption).foregroundStyle(.secondary)
            }
        case .repository(let result):
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: result.is_official ? "checkmark.seal.fill" : "shippingbox")
                    .foregroundStyle(result.is_official ? Tone.info.text : .secondary)
                    .accessibilityLabel(result.is_official ? Text("Official image") : Text("Image"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name).fontWeight(.medium)
                    if !result.description.isEmpty {
                        Text(result.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if result.star_count > 0 {
                    Label(result.star_count.formatted(.number.notation(.compactName)), systemImage: "star")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .tag(let name, let tag):
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                Text(tag).fontWeight(.medium)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
