import SwiftUI
import ContainerKit

/// "Run an App" for people new to Kubernetes: asks what the app is and who
/// should reach it, finds its port itself, and then shows what it made —
/// the objects, the kubectl commands and the YAML, explained.
struct RunAppSheet: View {
    let cluster: String
    let nodeAddress: String?
    let model: ClusterModel
    let clusters: ClustersModel
    let onEditYAML: (String) -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// What to run, how many copies, how to reach it; then it runs.
    enum Page: Int { case image, copies, reach, running, done }

    @State private var page: Page = .image
    /// Opens further along with an image chosen (snapshots).
    var startingAt: (page: Page, image: String)?
    @State private var plan: RunAppPlan = { var plan = RunAppPlan(); plan.replicas = 2; return plan }()
    @State private var nameEdited = false
    @State private var portText = ""
    @State private var environment: [EnvRow] = []
    @State private var result: RunAppResult?
    @State private var failed = false
    @State private var suggester = ImageSuggester()
    /// Set while the image comes from a menu or an example, not typing.
    @State private var picked = false
    /// The port its image declares, looked up on the way to step 2.
    @State private var detectedPort: Int?

    struct EnvRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    /// Ready-made starting points.
    struct Example: Identifiable {
        let image: String
        let what: String
        let kind: RunAppPlan.Kind
        var environment: [(key: String, value: String)] = []
        var id: String { image }
    }

    static let examples = [
        Example(image: "nginx:alpine", what: String(localized: "a web server that shows a welcome page"), kind: .web),
        Example(image: "httpd:alpine", what: String(localized: "the Apache web server"), kind: .web),
        Example(image: "redis:7-alpine", what: String(localized: "a cache other apps connect to"), kind: .internalService),
        Example(image: "postgres:17-alpine", what: String(localized: "a database other apps connect to"), kind: .internalService,
                environment: [("POSTGRES_PASSWORD", "postgres")]),
    ]

    private var localImages: [String] { app.model.images.filter { !$0.isSystem }.map(\.reference).sorted() }
    private var isLocal: Bool { localImages.contains(plan.image) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Group {
                        switch page {
                        case .image: imagePage
                        case .copies: copiesPage
                        case .reach: reachPage
                        case .running, .done: progressPage
                        }
                    }
                    .padding(DS.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                footer.padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.l)
            }
        }
        .frame(width: 760, height: 560)
        .onAppear {
            if let startingAt {
                choose(startingAt.image)
                page = startingAt.page
            }
        }
    }

    // MARK: - Steps

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Run an App").font(.title3.weight(.semibold))
            Text("in \(cluster)").font(.caption).foregroundStyle(.secondary).padding(.top, -DS.Spacing.s)
            step(1, "What to run", .image)
            step(2, "How many copies", .copies)
            step(3, "How to reach it", .reach)
            Spacer()
            Text("Everything you choose here becomes a few lines of YAML. You can see them on the right and keep them for later.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Spacing.m)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.accent.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.accent.opacity(0.15)))
        }
        .padding(DS.Spacing.l)
        .frame(width: 210, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.accent.opacity(0.04))
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ which: Page) -> some View {
        let done = page.rawValue > which.rawValue
        let current = page == which
        return HStack(spacing: DS.Spacing.s) {
            ZStack {
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Tone.positive.text)
                } else {
                    Circle().fill(current ? DS.accent : Color.clear)
                    Circle().strokeBorder(current ? Color.clear : Color.secondary.opacity(0.5))
                    Text(verbatim: "\(number)").font(.caption2.weight(.semibold)).foregroundStyle(current ? .white : .secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.callout.weight(current ? .semibold : .regular))
                .foregroundStyle(done ? Tone.positive.text : current ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "done" : current ? "current step" : "")
    }

    // MARK: - 1. Image

    private var imagePage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.xs) {
                Text("What should run?").font(.title2.weight(.bold))
                TermInfo(.image)
            }
            Text("Apps come packaged as images. Type one from Docker Hub or another registry, pick one already on this Mac, or start from an example.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Image", text: $plan.image, prompt: Text("nginx:alpine"))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.mono)
                    .imageSuggestions(suggester)
                if !localImages.isEmpty {
                    Menu("On This Mac") {
                        ForEach(localImages, id: \.self) { reference in Button(reference) { choose(reference) } }
                    }
                    .fixedSize()
                }
            }
            .onChange(of: plan.image) { _, value in
                if !nameEdited { plan.name = KubeDeployment.suggestedName(for: value) }
                if picked { picked = false; suggester.clear() } else { suggester.suggest(value, local: localImages) }
            }
            if let note = suggester.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if isLocal {
                Label("It's on this Mac: it will be copied into the cluster, no registry needed.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Examples").font(.headline).padding(.top, DS.Spacing.s)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: DS.Spacing.m)], spacing: DS.Spacing.m) {
                ForEach(Self.examples) { example in
                    Button { choose(example) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(example.image).font(DS.Font.mono.weight(.semibold))
                            Text(example.what).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(DS.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                            .fill(plan.image == example.image ? DS.accent.opacity(0.12) : DS.surface))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control)
                            .strokeBorder(plan.image == example.image ? DS.accent : DS.separator))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func choose(_ reference: String) {
        picked = reference != plan.image
        plan.image = reference
        nameEdited = false
        plan.name = KubeDeployment.suggestedName(for: reference)
    }

    private func choose(_ example: Example) {
        choose(example.image)
        plan.kind = example.kind
        environment = example.environment.map { EnvRow(key: $0.key, value: $0.value) }
    }

    // MARK: - 2. Copies

    private var appName: String { KubeDeployment.suggestedName(for: plan.image) }

    private var copiesPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("How many copies of \(Text(appName).font(.system(.title2, design: .monospaced).weight(.bold)))?")
                    .font(.title2.weight(.bold))
                Text("Kubernetes keeps this many running. If one crashes, it starts a new one.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Spacing.m) {
                copies(1, "Fine for trying things")
                copies(2, "Survives a crash · recommended")
                copies(3, "Spreads the work further")
            }
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("Port inside the app").font(.callout.weight(.semibold))
                HStack(spacing: DS.Spacing.s) {
                    TextField("Port", text: $portText, prompt: Text("auto", comment: "Port: found automatically"))
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Font.mono)
                        .frame(width: 90)
                    if let detectedPort, portText == String(detectedPort) {
                        Label("Found automatically: \(appName) listens on \(String(detectedPort))", systemImage: "checkmark")
                            .font(.callout).foregroundStyle(Tone.positive.text)
                    } else if portText.isEmpty {
                        Text("Leave it empty: Irekobox looks inside the running app.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.raised))
            yamlPreview
        }
        .task(id: plan.image) { await detectPort() }
    }

    private func copies(_ count: Int, _ detail: LocalizedStringKey) -> some View {
        let chosen = plan.replicas == count
        return Button { plan.replicas = count } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { _ in Circle().fill(Tone.positive.fill).frame(width: 8, height: 8) }
                }
                Text("\(count) copies").font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(chosen ? DS.accent : DS.separator.opacity(0.6), lineWidth: chosen ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The lines the choices so far become.
    private var yamlPreview: some View {
        let mono = Font.system(size: 12, design: .monospaced)
        let port = portText.isEmpty ? String(localized: "auto", comment: "Port: found automatically") : portText
        return VStack(alignment: .leading, spacing: 3) {
            Text("# what this creates").foregroundStyle(.white.opacity(0.5))
            Text(verbatim: "kind: Deployment")
            Text(verbatim: "spec:")
            Text(verbatim: "  replicas: \(plan.replicas)")
                .background(RoundedRectangle(cornerRadius: 3).fill(DS.accent.opacity(0.45)).padding(.horizontal, -3))
                .padding(.leading, 8)
            Text(verbatim: "  containers: [{ image: \(plan.image), port: \(port) }]")
        }
        .font(mono)
        .foregroundStyle(.white.opacity(0.9))
        .textSelection(.enabled)
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(Color(red: 0.12, green: 0.12, blue: 0.13)))
    }

    /// The port the image says it listens on, from this Mac or its registry.
    private func detectPort() async {
        let image = plan.image.trimmingCharacters(in: .whitespaces)
        guard let reference = ImageReference(image), !image.hasSuffix(":") else { return }
        var config: ImageDetails.OCIConfig?
        if let match = localImages.first(where: { $0 == image || $0 == reference.canonical }) {
            config = (try? await app.engine.inspectImage(match))?.variant()?.config // best-effort: only a suggestion
        } else {
            config = try? await RegistryClient().config(of: reference.canonical)
        }
        let ports = (config?.config?.ExposedPorts?.keys).map(Array.init)?.compactMap { key -> Int? in
            let parts = key.split(separator: "/")
            return parts.count < 2 || parts[1] == "tcp" ? Int(parts[0]) : nil
        }.sorted() ?? []
        guard !Task.isCancelled, let first = ports.first else { return }
        detectedPort = first
        if portText.isEmpty { portText = String(first) }
    }

    // MARK: - 3. Reach

    private var reachPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("How do you reach it?").font(.title2.weight(.bold))
                Text("This decides its address. Kubernetes calls the address in front of an app a Service.")
                    .foregroundStyle(.secondary)
            }
            choice(.web, "A website or an API", "People or other apps connect to it over the network.", "globe")
            choice(.internalService, "Something other apps use", "A database, a cache, a queue: only apps in the cluster connect to it.",
                   "cylinder.split.1x2")
            choice(.worker, "A background worker", "Nothing connects to it; it does its job on its own.", "gearshape.2")
            if plan.kind == .web {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Who opens it?").font(.headline)
                    TermInfo(.nodePort)
                }
                Picker("Who opens it?", selection: $plan.audience) {
                    Text("Me, in a browser on this Mac").tag(RunAppPlan.Audience.mac)
                    Text("Only other apps in the cluster").tag(RunAppPlan.Audience.cluster)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            DisclosureGroup("Name, namespace and settings") { details }
        }
    }

    private func choice(_ kind: RunAppPlan.Kind, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ icon: String) -> some View {
        Button { plan.kind = kind } label: {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                    .foregroundStyle(plan.kind == kind ? DS.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: plan.kind == kind ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(plan.kind == kind ? DS.accent : .secondary)
            }
            .padding(DS.Spacing.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(plan.kind == kind ? DS.accent.opacity(0.1) : DS.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(plan.kind == kind ? DS.accent : DS.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(plan.kind == kind ? .isSelected : [])
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            LabeledContent("Name") {
                TextField("Name", text: Binding(get: { plan.name }, set: { plan.name = $0; nameEdited = true }))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            LabeledContent {
                TextField("Namespace", text: $plan.namespace).textFieldStyle(.roundedBorder).labelsHidden()
            } label: {
                HStack(spacing: DS.Spacing.xs) { Text("Namespace"); TermInfo(.namespace) }
            }
            ForEach($environment) { $row in
                HStack {
                    TextField("Variable", text: $row.key).font(DS.Font.mono).textFieldStyle(.roundedBorder)
                    TextField("Value", text: $row.value).font(DS.Font.mono).textFieldStyle(.roundedBorder)
                    Button { [id = row.id] in environment.removeAll { $0.id == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove variable")
                }
            }
            HStack {
                Button { environment.append(EnvRow()) } label: { Label("Add Environment Variable", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Edit as YAML…") { onEditYAML(previewDeployment.annotatedYAML); dismiss() }
                    .buttonStyle(.link)
                    .help("Open the manifests in the editor to change anything this form doesn't")
            }
            Text("Its Deployment, pods and Service are named after it.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, DS.Spacing.s)
    }

    private var previewDeployment: KubeDeployment {
        KubeDeployment(name: plan.name, namespace: plan.namespace, image: plan.image, replicas: plan.replicas,
                       port: Int(portText), exposure: plan.kind == .worker ? .none : plan.audience == .mac && plan.kind == .web ? .mac : .cluster,
                       environment: environment.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
                       createNamespace: !(model.snapshot?.namespaces.contains(plan.namespace) ?? false))
    }

    // MARK: - Running, done

    private var progressPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    ForEach(model.runSteps) { step in stepRow(step) }
                }
                if let result { learn(result) }
            }
        }
    }

    private func stepRow(_ step: RunAppStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Group {
                switch step.state {
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.positive.fill)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Tone.critical.fill)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).foregroundStyle(step.state == .skipped ? .secondary : .primary)
                switch step.state {
                case .done(let note?): Text(note).font(.caption).foregroundStyle(.secondary)
                case .failed(let reason): Text(reason).font(.caption).foregroundStyle(Tone.critical.text)
                    .fixedSize(horizontal: false, vertical: true)
                default: EmptyView()
                }
            }
        }
    }

    /// What just happened, in Kubernetes terms, so next time it's familiar.
    private func learn(_ result: RunAppResult) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if let url = result.url {
                HStack {
                    Label("\(plan.name) is running.", systemImage: "checkmark.seal.fill").foregroundStyle(Tone.positive.text)
                        .font(.headline)
                    Spacer()
                    Button { openURL(url) } label: { Label("Open \(url.absoluteString)", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Label("\(plan.name) is running.", systemImage: "checkmark.seal.fill").foregroundStyle(Tone.positive.text)
                    .font(.headline)
                if let address = result.internalAddress {
                    Text("Other apps in the cluster reach it at \(address).").textSelection(.enabled)
                }
            }
            Text("What just happened").font(.headline).padding(.top, DS.Spacing.s)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                explained(.deployment, plan.replicas == 1
                          ? "A Deployment named \(plan.name) keeps one pod of \(plan.image) running, and starts a new one if one stops."
                          : "A Deployment named \(plan.name) keeps \(plan.replicas) pods of \(plan.image) running, and starts a new one if one stops.")
                if let port = result.port {
                    explained(.pod, result.detected
                              ? "Looking inside its pod, the app listens on port \(String(port)), so that's where traffic goes."
                              : "The app listens on port \(String(port)).")
                    explained(.service, result.url != nil
                              ? "A Service named \(plan.name) gives it a stable address; its node port lets this Mac open it."
                              : "A Service named \(plan.name) gives it a stable address other apps use.")
                }
            }
            Text("The same with kubectl").font(.headline).padding(.top, DS.Spacing.s)
            CodeBlock(text: result.deployment.kubectlCommands.joined(separator: "\n"))
            DisclosureGroup("As YAML, explained") {
                CodeBlock(text: result.deployment.annotatedYAML)
            }
        }
    }

    private func explained(_ term: Glossary, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(term.title).font(.callout.weight(.semibold)).frame(width: 96, alignment: .leading)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            TermInfo(term)
        }
    }

    // MARK: - Footer

    private var canContinue: Bool {
        switch page {
        case .image:
            // A chosen repository ends in ":" until its tag is picked.
            let image = plan.image.trimmingCharacters(in: .whitespaces)
            return !image.isEmpty && !image.hasSuffix(":")
        case .copies:
            return portText.isEmpty || Int(portText).map { (1...65535).contains($0) } == true
        case .reach:
            return KubeDeployment.isValidName(plan.name) && KubeDeployment.isValidName(plan.namespace)
        default: return true
        }
    }

    private var footer: some View {
        HStack {
            switch page {
            case .image, .copies, .reach:
                Button("Cancel") { dismiss() }
                    .buttonStyle(.automatic)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if page != .image {
                    Button("Back") { page = Page(rawValue: page.rawValue - 1) ?? .image }
                        .buttonStyle(.automatic)
                }
                Button(page == .reach ? "Run" : "Continue") {
                    if page == .reach { run() } else { page = Page(rawValue: page.rawValue + 1) ?? .reach }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            case .running:
                Spacer()
                Button("Cancel") {}.buttonStyle(.automatic).disabled(true)
            case .done:
                Spacer()
                if failed { Button("Back") { page = .reach }.buttonStyle(.automatic) }
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func run() {
        plan.image = plan.image.trimmingCharacters(in: .whitespaces)
        plan.port = Int(portText)
        plan.environment = environment.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }
        page = .running
        Task {
            result = await model.runApp(plan, localImage: isLocal, clusters: clusters, nodeAddress: nodeAddress)
            failed = result == nil
            if !failed { Milestone.ranKubernetesApp.reach() }
            if !failed { model.namespace = plan.namespace == "default" ? model.namespace : plan.namespace }
            page = .done
        }
    }
}

/// Monospaced text to read and copy.
struct CodeBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Text(text).font(DS.Font.monoSmall).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(value: text)
        }
        .padding(DS.Spacing.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.subtleFill))
    }
}
