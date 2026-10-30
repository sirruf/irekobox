import SwiftUI

/// Plain explanations of the terms the app shows, for people new to them.
enum Glossary: String, CaseIterable {
    case pod, deployment, statefulSet, daemonSet, replicas, service, nodePort, clusterOnly, namespace
    case configMap, secret, volumeClaim, image, rolloutRestart, cluster, node, kubectl
    case container, composeProject, machine, volume, network, publishedPort, environment, platform, resources

    var title: String {
        switch self {
        case .pod: return String(localized: "Pod")
        case .deployment: return String(localized: "Deployment")
        case .statefulSet: return String(localized: "StatefulSet")
        case .daemonSet: return String(localized: "DaemonSet")
        case .replicas: return String(localized: "Copies (replicas)")
        case .service: return String(localized: "Service")
        case .nodePort: return String(localized: "Node port")
        case .clusterOnly: return String(localized: "Inside the cluster only")
        case .namespace: return String(localized: "Namespace")
        case .configMap: return String(localized: "ConfigMap")
        case .secret: return String(localized: "Secret")
        case .volumeClaim: return String(localized: "Volume claim (PVC)")
        case .image: return String(localized: "Image")
        case .rolloutRestart: return String(localized: "Restart")
        case .cluster: return String(localized: "Cluster")
        case .node: return String(localized: "Node")
        case .kubectl: return String(localized: "kubectl")
        case .container: return String(localized: "Container")
        case .composeProject: return String(localized: "Compose project")
        case .machine: return String(localized: "Machine")
        case .volume: return String(localized: "Volume")
        case .network: return String(localized: "Network")
        case .publishedPort: return String(localized: "Ports")
        case .environment: return String(localized: "Environment variables")
        case .platform: return String(localized: "Platform")
        case .resources: return String(localized: "Resources")
        }
    }

    var text: String {
        switch self {
        case .pod:
            return String(localized: "One running copy of an app: its container, with its own address inside the cluster. Pods come and go; Kubernetes replaces them, so you rarely manage them one by one.")
        case .deployment:
            return String(localized: "Keeps a number of identical pods running. If one crashes it starts another; when you change the app it replaces them one by one. Most apps are deployments.")
        case .statefulSet:
            return String(localized: "Like a deployment, but each pod keeps its name and its own storage across restarts. Used for databases.")
        case .daemonSet:
            return String(localized: "Runs one pod on every node of the cluster. Used for helpers such as networking or log collection, not for your apps.")
        case .replicas:
            return String(localized: "How many pods of the app run at once. Two or more share the work and keep the app up while one restarts.")
        case .service:
            return String(localized: "A stable name and port in front of an app's pods. Other apps connect to the name (for example web.shop); the pods behind it can change without anyone noticing.")
        case .nodePort:
            return String(localized: "A port on the cluster's node, between 30000 and 32767. This Mac can open it in a browser at the node's address.")
        case .clusterOnly:
            return String(localized: "Other apps in the cluster reach it by its service name; it can't be opened from this Mac. Right for databases and internal APIs.")
        case .namespace:
            return String(localized: "A folder for apps inside the cluster, to keep projects apart. \"default\" is fine to start with.")
        case .configMap:
            return String(localized: "Settings kept in the cluster (files or values) that pods read, so the image needn't change when settings do.")
        case .secret:
            return String(localized: "Like a ConfigMap, for passwords and keys.")
        case .volumeClaim:
            return String(localized: "Storage an app asks for. Its files stay when pods are replaced; deleting the claim deletes them.")
        case .image:
            return String(localized: "The packaged app to run, such as nginx:alpine. One built or pulled on this Mac is copied into the cluster when you run it.")
        case .rolloutRestart:
            return String(localized: "Replaces the app's pods with fresh ones, one at a time, so it stays reachable meanwhile. Use it to pick up changed settings.")
        case .cluster:
            return String(localized: "A small Kubernetes on this Mac: nodes running as containers. You tell it which apps to run and how; it keeps them that way.")
        case .node:
            return String(localized: "A machine of the cluster where pods run; here, a container on this Mac.")
        case .kubectl:
            return String(localized: "Kubernetes' command-line tool. Everything this page does, kubectl can do too; Connect kubectl shows how to point it at this cluster.")
        case .container:
            return String(localized: "An app running in isolation from an image, in its own small Linux VM here. Stop it and start it again; delete it and its own files go, its volumes stay.")
        case .composeProject:
            return String(localized: "Several containers described in one compose.yaml (a web app, its database, a cache) and started together, with a network so they find each other by name.")
        case .machine:
            return String(localized: "A whole Linux system with your account and your home folder, for working in a shell: install tools, build, try things. Containers are still the way to run services.")
        case .volume:
            return String(localized: "Storage kept outside containers, so data survives when a container is deleted or recreated. Databases keep their files in one.")
        case .network:
            return String(localized: "Containers on the same network reach each other by name. Separate networks keep apps apart.")
        case .publishedPort:
            return String(localized: "Publishing a port makes the app reachable from this Mac: localhost:8080 → port 80 inside. Without it only other containers reach the app.")
        case .environment:
            return String(localized: "Settings an app reads at start, like DATABASE_URL=… or a password. Images document the ones they understand.")
        case .platform:
            return String(localized: "The processor the image is built for. arm64 runs natively on Apple silicon; amd64 images run through Rosetta, a little slower.")
        case .resources:
            return String(localized: "How many CPUs and how much memory the container's VM gets. Defaults suit most apps; databases and builds like more memory.")
        }
    }
}

extension Glossary {
    /// The nearest Docker idea, for people who know Docker.
    var inDocker: String? {
        switch self {
        case .pod: return String(localized: "about one container")
        case .deployment: return String(localized: "a compose service with several replicas")
        case .statefulSet: return String(localized: "a database service with its own volume")
        case .service: return String(localized: "a service name on a compose network")
        case .nodePort: return String(localized: "a published port")
        case .namespace: return String(localized: "a compose project")
        case .configMap: return String(localized: "an env_file or a mounted config file")
        case .secret: return String(localized: "a compose secret")
        case .volumeClaim: return String(localized: "a named volume")
        case .rolloutRestart: return String(localized: "docker compose up --force-recreate, one at a time")
        case .cluster: return String(localized: "docker swarm, on one Mac")
        case .kubectl: return String(localized: "the docker command, for Kubernetes")
        case .composeProject: return String(localized: "docker compose")
        case .container: return String(localized: "docker run")
        default: return nil
        }
    }

    /// Where to read more: Kubernetes' own concepts pages.
    var learnMore: URL? {
        let base = "https://kubernetes.io/docs/concepts/"
        let path: String? = switch self {
        case .pod: "workloads/pods/"
        case .deployment, .replicas, .rolloutRestart: "workloads/controllers/deployment/"
        case .statefulSet: "workloads/controllers/statefulset/"
        case .daemonSet: "workloads/controllers/daemonset/"
        case .service, .nodePort, .clusterOnly: "services-networking/service/"
        case .namespace: "overview/working-with-objects/namespaces/"
        case .configMap: "configuration/configmap/"
        case .secret: "configuration/secret/"
        case .volumeClaim: "storage/persistent-volumes/"
        case .cluster, .node: "architecture/nodes/"
        default: nil
        }
        return path.flatMap { URL(string: base + $0) }
    }
}

/// An ⓘ that explains a term in a popover.
struct TermInfo: View {
    let term: Glossary
    @State private var shown = false
    /// Settings › Learning.
    @AppStorage(LearningSettings.explainTerms) private var explainTerms = true

    init(_ term: Glossary) { self.term = term }

    var body: some View {
        if explainTerms { button }
    }

    private var button: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("About \(term.title)")
        .accessibilityLabel("About \(term.title)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(term.title).font(.headline)
                Text(term.text).fixedSize(horizontal: false, vertical: true)
                if let docker = term.inDocker {
                    Text("In Docker terms: \(docker).").font(.callout).foregroundStyle(.secondary)
                }
                if let url = term.learnMore {
                    Link("Learn more about Kubernetes", destination: url).font(.callout)
                }
            }
            .padding(DS.Spacing.l)
            .frame(width: 320)
        }
    }
}

/// A section title with a plain subtitle and an ⓘ.
struct ExplainedHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var term: Glossary?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Spacing.xs) {
                Text(title).font(.headline)
                if let term { TermInfo(term) }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings › Learning: how much the app explains as you go.
enum LearningSettings {
    /// The blue notes that say what a screen is about.
    static let showNotes = "learning.showNotes"
    /// The ⓘ beside terms such as Service or Namespace.
    static let explainTerms = "learning.explainTerms"
}

/// A short explanation on a blue band, for people new to containers;
/// hidden when Settings › Learning turns notes off.
struct LearnNote: View {
    let text: LocalizedStringKey
    @AppStorage(LearningSettings.showNotes) private var showNotes = true

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        if showNotes {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(DS.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.accent.opacity(0.06)))
                .hairline(RoundedRectangle(cornerRadius: DS.Radius.card), DS.accent.opacity(0.25))
        }
    }
}
