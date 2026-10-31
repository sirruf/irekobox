import ComposeKit
import SwiftUI

/// Starter projects: a compose.yaml that runs as is, to learn from or build on.
struct ComposeTemplate: Identifiable, Hashable {
    let id: String
    let category: Category
    let title: String
    let about: String
    let systemImage: String
    /// Where to look once it runs.
    let opens: String
    let yaml: String

    /// Groups in the catalog, in this order.
    enum Category: CaseIterable {
        case basics, develop, data, monitor, selfHost

        var title: String {
            switch self {
            case .basics: String(localized: "Basics", comment: "Compose template group")
            case .develop: String(localized: "Develop", comment: "Compose template group")
            case .data: String(localized: "Data", comment: "Compose template group")
            case .monitor: String(localized: "Monitor", comment: "Compose template group")
            case .selfHost: String(localized: "Self-Host", comment: "Compose template group")
            }
        }

        /// The icon tiles' colour.
        var tint: Color {
            switch self {
            case .basics: DS.dynamic(light: 0x2A78D6, dark: 0x3987E5)
            case .develop: DS.dynamic(light: 0x5856D6, dark: 0x7D7AFF)
            case .data: DS.disk
            case .monitor: DS.dynamic(light: 0x248A3D, dark: 0x30B350)
            case .selfHost: DS.memory
            }
        }
    }

    static let all: [ComposeTemplate] = [
        web, nodeRedis, devServices, postgres, mongo, kafka, jupyter,
        monitoring, uptimeKuma, wordpress, ghost, nextcloud, gitea, n8n,
    ]
    /// Shown on the Compose screen next to the drop zone.
    static let featured: [ComposeTemplate] = [devServices, postgres, wordpress, monitoring]

    /// The services it runs, in file order, with the ports they publish.
    var services: [(name: String, image: String, ports: [String])] {
        guard let file = try? ComposeParser().parse(yaml).file else { return [] }
        return file.services
            .map { name, service in
                (name: name, image: service.image ?? "",
                 ports: (service.ports ?? []).compactMap { $0.published.map { "localhost:\($0)" } })
            }
            .sorted { (yaml.range(of: "\n  \($0.name):")?.lowerBound ?? yaml.endIndex)
                < (yaml.range(of: "\n  \($1.name):")?.lowerBound ?? yaml.endIndex) }
    }

    static let web = ComposeTemplate(
        id: "web", category: .basics, title: String(localized: "Web Server"), about: String(localized: "One nginx serving a page — the smallest project"),
        systemImage: "globe", opens: "http://localhost:8080",
        yaml: """
        # A compose project: each service is a container. Edit it here, then Apply.
        services:
          web:
            image: nginx:alpine
            ports:
              - "8080:80"
        """)

    static let wordpress = ComposeTemplate(
        id: "wordpress", category: .selfHost, title: String(localized: "WordPress"), about: String(localized: "WordPress with a MariaDB database kept in a volume"),
        systemImage: "doc.richtext", opens: "http://localhost:8080",
        yaml: """
        # WordPress and its database. The database keeps its data in the db-data volume.
        services:
          wordpress:
            image: wordpress:6
            ports:
              - "8080:80"
            environment:
              WORDPRESS_DB_HOST: db
              WORDPRESS_DB_USER: wordpress
              WORDPRESS_DB_PASSWORD: change-me
              WORDPRESS_DB_NAME: wordpress
            depends_on:
              - db
          db:
            image: mariadb:11
            environment:
              MARIADB_DATABASE: wordpress
              MARIADB_USER: wordpress
              MARIADB_PASSWORD: change-me
              MARIADB_RANDOM_ROOT_PASSWORD: "1"
            volumes:
              - db-data:/var/lib/mysql
        volumes:
          db-data:
        """)

    static let postgres = ComposeTemplate(
        id: "postgres", category: .develop, title: String(localized: "Postgres + Adminer"), about: String(localized: "A database and a web page to look into it"),
        systemImage: "cylinder.split.1x2", opens: "http://localhost:8081",
        yaml: """
        # Postgres on localhost:5432, and Adminer to browse it on localhost:8081
        # (system PostgreSQL, server db, user postgres).
        services:
          db:
            image: postgres:17-alpine
            ports:
              - "5432:5432"
            environment:
              POSTGRES_PASSWORD: change-me
            volumes:
              - pgdata:/var/lib/postgresql/data
          adminer:
            image: adminer
            ports:
              - "8081:8080"
            depends_on:
              - db
        volumes:
          pgdata:
        """)

    static let nodeRedis = ComposeTemplate(
        id: "node-redis", category: .basics, title: String(localized: "Node + Redis"), about: String(localized: "A small Node server counting visits in Redis"),
        systemImage: "bolt.horizontal", opens: "http://localhost:3000",
        yaml: """
        # A Node app that counts visits in Redis. Replace the command with your own app
        # (mount its folder and run npm start).
        services:
          app:
            image: node:22-alpine
            ports:
              - "3000:3000"
            environment:
              REDIS_HOST: cache
            command:
              - node
              - -e
              - |
                const net = require("net"), http = require("http");
                http.createServer((req, res) => {
                  const r = net.connect(6379, process.env.REDIS_HOST);
                  r.write("INCR visits\\r\\n");
                  r.once("data", d => { res.end("Visits: " + String(d).slice(1)); r.end(); });
                  r.on("error", e => res.end("Redis isn't up yet: " + e.message));
                }).listen(3000);
            depends_on:
              - cache
          cache:
            image: redis:7-alpine
        """)

    static let ghost = ComposeTemplate(
        id: "ghost", category: .selfHost, title: String(localized: "Ghost"), about: String(localized: "A blog with its content kept in a volume"),
        systemImage: "text.book.closed", opens: "http://localhost:2368",
        yaml: """
        # Ghost, a blog, on localhost:2368 (admin at /ghost). Posts live in the ghost-content volume.
        services:
          ghost:
            image: ghost:5
            ports:
              - "2368:2368"
            environment:
              url: http://localhost:2368
              database__client: sqlite3
              database__connection__filename: /var/lib/ghost/content/data/ghost.db
            volumes:
              - ghost-content:/var/lib/ghost/content
        volumes:
          ghost-content:
        """)

    static let devServices = ComposeTemplate(
        id: "dev-services", category: .develop, title: String(localized: "Dev Services"),
        about: String(localized: "Postgres, Redis, a mail catcher and S3 storage for your app"),
        systemImage: "hammer", opens: "http://localhost:8025",
        yaml: """
        # What an app under development needs next to it, all on localhost:
        # Postgres 5432, Redis 6379, mail caught by Mailpit (SMTP 1025, inbox on 8025)
        # and S3-compatible storage by SeaweedFS (endpoint http://localhost:8333).
        services:
          postgres:
            image: postgres:17-alpine
            ports:
              - "127.0.0.1:5432:5432"
            environment:
              POSTGRES_PASSWORD: change-me
            volumes:
              - pgdata:/var/lib/postgresql/data
          redis:
            image: redis:7-alpine
            ports:
              - "127.0.0.1:6379:6379"
          mailpit:
            image: axllent/mailpit
            ports:
              - "127.0.0.1:1025:1025"
              - "127.0.0.1:8025:8025"
          s3:
            image: chrislusf/seaweedfs
            command: ["server", "-s3", "-dir=/data"]
            ports:
              - "127.0.0.1:8333:8333"
            volumes:
              - s3data:/data
        volumes:
          pgdata:
          s3data:
        """)

    static let mongo = ComposeTemplate(
        id: "mongo", category: .data, title: String(localized: "MongoDB"),
        about: String(localized: "MongoDB with mongo-express to browse it"),
        systemImage: "leaf", opens: "http://localhost:8084",
        yaml: """
        # MongoDB on localhost:27017 (user root / change-me) and mongo-express to
        # browse it on localhost:8084. The data lives in the mongo-data volume.
        services:
          mongo:
            image: mongo:8
            ports:
              - "127.0.0.1:27017:27017"
            environment:
              MONGO_INITDB_ROOT_USERNAME: root
              MONGO_INITDB_ROOT_PASSWORD: change-me
            volumes:
              - mongo-data:/data/db
          mongo-express:
            image: mongo-express
            ports:
              - "127.0.0.1:8084:8081"
            environment:
              ME_CONFIG_MONGODB_URL: mongodb://root:change-me@mongo:27017/
              ME_CONFIG_BASICAUTH: "false"
            depends_on:
              - mongo
        volumes:
          mongo-data:
        """)

    static let kafka = ComposeTemplate(
        id: "kafka", category: .data, title: String(localized: "Kafka"),
        about: String(localized: "One Kafka broker without ZooKeeper, with Kafka UI"),
        systemImage: "arrow.left.arrow.right", opens: "http://localhost:8083",
        yaml: """
        # Kafka without ZooKeeper (KRaft), one broker: apps on this Mac connect to
        # localhost:9092, other containers to kafka:19092. Kafka UI on localhost:8083.
        services:
          kafka:
            image: apache/kafka:3.9.0
            ports:
              - "127.0.0.1:9092:9092"
            environment:
              KAFKA_NODE_ID: "1"
              KAFKA_PROCESS_ROLES: broker,controller
              KAFKA_LISTENERS: INTERNAL://:19092,EXTERNAL://:9092,CONTROLLER://:9093
              KAFKA_ADVERTISED_LISTENERS: INTERNAL://kafka:19092,EXTERNAL://localhost:9092
              KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT
              KAFKA_INTER_BROKER_LISTENER_NAME: INTERNAL
              KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
              KAFKA_CONTROLLER_QUORUM_VOTERS: 1@localhost:9093
              KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: "1"
              KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: "1"
              KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: "1"
              KAFKA_HEAP_OPTS: -Xmx512m -Xms512m
            volumes:
              - kafka-data:/var/lib/kafka/data
          kafka-ui:
            image: provectuslabs/kafka-ui
            ports:
              - "127.0.0.1:8083:8080"
            environment:
              KAFKA_CLUSTERS_0_NAME: local
              KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:19092
            depends_on:
              - kafka
        volumes:
          kafka-data:
        """)

    static let jupyter = ComposeTemplate(
        id: "jupyter", category: .data, title: String(localized: "Jupyter"),
        about: String(localized: "JupyterLab with NumPy, pandas and Matplotlib"),
        systemImage: "chart.xyaxis.line", opens: "http://localhost:8888/lab?token=change-me",
        yaml: """
        # JupyterLab with NumPy, pandas and Matplotlib on localhost:8888 (token
        # change-me). Notebooks saved under work/ stay in the notebooks volume.
        services:
          jupyter:
            image: quay.io/jupyter/scipy-notebook
            command: ["start-notebook.py", "--IdentityProvider.token=change-me"]
            ports:
              - "127.0.0.1:8888:8888"
            volumes:
              - notebooks:/home/jovyan/work
        volumes:
          notebooks:
        """)

    static let monitoring = ComposeTemplate(
        id: "monitoring", category: .monitor, title: String(localized: "Prometheus + Grafana"),
        about: String(localized: "Metrics collected by Prometheus, drawn by Grafana, already connected"),
        systemImage: "gauge.with.dots.needle.67percent", opens: "http://localhost:3000",
        yaml: """
        # Prometheus collects metrics, Grafana draws them: open localhost:3000, the
        # Prometheus data source is already there. node-exporter reports the machine
        # it runs in. Edit the scrape list in the prometheus command to add your apps.
        services:
          prometheus:
            image: prom/prometheus
            entrypoint: sh
            command:
              - -c
              - |
                cat > /tmp/prometheus.yml <<'YAML'
                global:
                  scrape_interval: 15s
                scrape_configs:
                  - job_name: prometheus
                    static_configs:
                      - targets: ["localhost:9090"]
                  - job_name: node
                    static_configs:
                      - targets: ["node-exporter:9100"]
                YAML
                exec /bin/prometheus --config.file=/tmp/prometheus.yml --storage.tsdb.path=/prometheus
            ports:
              - "127.0.0.1:9090:9090"
            volumes:
              - prometheus-data:/prometheus
          node-exporter:
            image: prom/node-exporter
          grafana:
            image: grafana/grafana-oss
            entrypoint: sh
            command:
              - -c
              - |
                mkdir -p /tmp/provisioning/datasources
                cat > /tmp/provisioning/datasources/prometheus.yaml <<'YAML'
                apiVersion: 1
                datasources:
                  - name: Prometheus
                    type: prometheus
                    url: http://prometheus:9090
                    isDefault: true
                YAML
                exec /run.sh
            ports:
              - "127.0.0.1:3000:3000"
            environment:
              GF_PATHS_PROVISIONING: /tmp/provisioning
              GF_AUTH_ANONYMOUS_ENABLED: "true"
              GF_AUTH_ANONYMOUS_ORG_ROLE: Admin
            volumes:
              - grafana-data:/var/lib/grafana
            depends_on:
              - prometheus
        volumes:
          prometheus-data:
          grafana-data:
        """)

    static let uptimeKuma = ComposeTemplate(
        id: "uptime-kuma", category: .monitor, title: String(localized: "Uptime Kuma"),
        about: String(localized: "Checks that your sites are up and shows their status"),
        systemImage: "waveform.path.ecg", opens: "http://localhost:3001",
        yaml: """
        # Uptime Kuma checks your sites and services and shows their status on
        # localhost:3001. Its settings and history live in the kuma-data volume.
        services:
          uptime-kuma:
            image: louislam/uptime-kuma:1
            ports:
              - "127.0.0.1:3001:3001"
            volumes:
              - kuma-data:/app/data
        volumes:
          kuma-data:
        """)

    static let nextcloud = ComposeTemplate(
        id: "nextcloud", category: .selfHost, title: String(localized: "Nextcloud"),
        about: String(localized: "Your own files, calendars and contacts, with MariaDB"),
        systemImage: "cloud", opens: "http://localhost:8082",
        yaml: """
        # Nextcloud, files and calendars of your own, on localhost:8082 (the first
        # visit creates the admin). Files and the MariaDB database live in volumes.
        services:
          nextcloud:
            image: nextcloud:30-apache
            ports:
              - "127.0.0.1:8082:80"
            environment:
              MYSQL_HOST: db
              MYSQL_DATABASE: nextcloud
              MYSQL_USER: nextcloud
              MYSQL_PASSWORD: change-me
            volumes:
              - nextcloud-data:/var/www/html
            depends_on:
              - db
          db:
            image: mariadb:11
            command: ["--transaction-isolation=READ-COMMITTED", "--binlog-format=ROW"]
            environment:
              MARIADB_DATABASE: nextcloud
              MARIADB_USER: nextcloud
              MARIADB_PASSWORD: change-me
              MARIADB_RANDOM_ROOT_PASSWORD: "1"
            volumes:
              - nextcloud-db:/var/lib/mysql
        volumes:
          nextcloud-data:
          nextcloud-db:
        """)

    static let gitea = ComposeTemplate(
        id: "gitea", category: .selfHost, title: String(localized: "Gitea"),
        about: String(localized: "Your own Git server with a Postgres database"),
        systemImage: "arrow.triangle.branch", opens: "http://localhost:3002",
        yaml: """
        # Your own Git server: Gitea on localhost:3002 (the first visit sets it up),
        # SSH clones on port 2222, repositories and its Postgres database in volumes.
        services:
          gitea:
            image: gitea/gitea:1
            ports:
              - "127.0.0.1:3002:3000"
              - "127.0.0.1:2222:22"
            environment:
              GITEA__server__ROOT_URL: http://localhost:3002/
              GITEA__server__SSH_PORT: "2222"
              GITEA__database__DB_TYPE: postgres
              GITEA__database__HOST: db:5432
              GITEA__database__NAME: gitea
              GITEA__database__USER: gitea
              GITEA__database__PASSWD: change-me
            volumes:
              - gitea-data:/data
            depends_on:
              - db
          db:
            image: postgres:17-alpine
            environment:
              POSTGRES_DB: gitea
              POSTGRES_USER: gitea
              POSTGRES_PASSWORD: change-me
            volumes:
              - gitea-db:/var/lib/postgresql/data
        volumes:
          gitea-data:
          gitea-db:
        """)

    static let n8n = ComposeTemplate(
        id: "n8n", category: .selfHost, title: String(localized: "n8n"),
        about: String(localized: "Workflows that connect apps and APIs"),
        systemImage: "point.3.filled.connected.trianglepath.dotted", opens: "http://localhost:5678",
        yaml: """
        # n8n connects apps and APIs into automated workflows, on localhost:5678.
        # Workflows and credentials live in the n8n-data volume.
        services:
          n8n:
            image: n8nio/n8n
            ports:
              - "127.0.0.1:5678:5678"
            environment:
              N8N_SECURE_COOKIE: "false"
              GENERIC_TIMEZONE: UTC
            volumes:
              - n8n-data:/home/node/.n8n
        volumes:
          n8n-data:
        """)
}

/// A template's icon: its symbol on a tile in its group's colour.
struct TemplateIcon: View {
    let template: ComposeTemplate
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: (size * 0.26).rounded(), style: .continuous)
            .fill(template.category.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: template.systemImage)
                    .font(.system(size: (size * 0.46).rounded(), weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The template catalog: groups of starters on the left, the chosen one
/// in detail on the right, then where its folder goes.
struct NewProjectSheet: View {
    var initial: ComposeTemplate = .web
    /// Called with the chosen template once a folder is picked.
    let create: (ComposeTemplate, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ComposeTemplate = .web
    @State private var name = "my-app"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                catalog.frame(width: 540)
                Divider()
                TemplateDetail(template: chosen)
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 620)
        .onAppear { select(initial) }
    }

    private var catalog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("New Compose Project").font(.title2.weight(.semibold))
                        Text("Start from one of these; it's a compose.yaml you can read and change. Nothing runs until you press Start.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(ComposeTemplate.Category.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            SectionHeader(category.title)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Spacing.s), GridItem(.flexible())],
                                      spacing: DS.Spacing.s) {
                                ForEach(ComposeTemplate.all.filter { $0.category == category }) { card($0) }
                            }
                        }
                    }
                }
                .padding(DS.Spacing.xl)
            }
            .onAppear { proxy.scrollTo(initial.id, anchor: .center) }
        }
        .background(DS.canvas)
    }

    private func card(_ template: ComposeTemplate) -> some View {
        let selected = chosen == template
        return Button { select(template) } label: {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                TemplateIcon(template: template, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title).font(.callout.weight(.semibold))
                    Text(template.about).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(DS.Spacing.m)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(selected ? DS.accent : DS.separator.opacity(0.6), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .id(template.id)
        .accessibilityLabel(template.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            Text("Folder name").foregroundStyle(.secondary)
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.automatic)
            Button("Choose Where") { choose() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(DS.Spacing.l)
    }

    private func select(_ template: ComposeTemplate) {
        chosen = template
        name = template.id == "web" ? "my-app" : template.id
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.title = String(localized: "New Compose Project")
        panel.prompt = String(localized: "Create")
        panel.nameFieldLabel = String(localized: "Folder:")
        panel.nameFieldStringValue = name.trimmingCharacters(in: .whitespaces)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        dismiss()
        create(chosen, folder)
    }
}

/// The chosen template: what it runs, where it opens, and its compose.yaml.
private struct TemplateDetail: View {
    let template: ComposeTemplate
    @State private var showYAML = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                HStack(spacing: DS.Spacing.m) {
                    TemplateIcon(template: template, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.title).font(.title3.weight(.semibold))
                        Text(template.category.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(template.about).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    SectionHeader("Runs")
                    ForEach(template.services, id: \.name) { service in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: service.name).font(.callout.weight(.medium))
                                Spacer(minLength: DS.Spacing.s)
                                Text(verbatim: service.ports.joined(separator: ", "))
                                    .font(DS.Font.monoSmall).foregroundStyle(.secondary)
                            }
                            Text(verbatim: service.image).font(DS.Font.monoSmall).foregroundStyle(.tertiary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    SectionHeader("Opens at")
                    Text(verbatim: template.opens).font(DS.Font.mono).textSelection(.enabled)
                }
                DisclosureGroup(isExpanded: $showYAML) {
                    Text(verbatim: template.yaml)
                        .font(DS.Font.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.s)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.subtleFill))
                        .padding(.top, DS.Spacing.xs)
                } label: {
                    Text(verbatim: "compose.yaml").font(.callout.weight(.medium))
                }
            }
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.raised)
    }
}
