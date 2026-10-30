import SwiftUI

/// Starter projects: a compose.yaml that runs as is, to learn from or build on.
struct ComposeTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let about: String
    let systemImage: String
    /// Where to look once it runs.
    let opens: String
    let yaml: String

    static let all: [ComposeTemplate] = [web, wordpress, postgres, nodeRedis, ghost]

    static let web = ComposeTemplate(
        id: "web", title: String(localized: "Web Server"), about: String(localized: "One nginx serving a page — the smallest project"),
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
        id: "wordpress", title: String(localized: "WordPress"), about: String(localized: "WordPress with a MariaDB database kept in a volume"),
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
        id: "postgres", title: String(localized: "Postgres + Adminer"), about: String(localized: "A database and a web page to look into it"),
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
        id: "node-redis", title: String(localized: "Node + Redis"), about: String(localized: "A small Node server counting visits in Redis"),
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
        id: "ghost", title: String(localized: "Ghost"), about: String(localized: "A blog with its content kept in a volume"),
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
}

/// Pick a starter, then where its folder goes.
struct NewProjectSheet: View {
    var initial: ComposeTemplate = .web
    /// Called with the chosen template once a folder is picked.
    let create: (ComposeTemplate, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ComposeTemplate = .web
    @State private var name = "my-app"

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("New Project").font(.title2.weight(.semibold))
            Text("Start from one of these; it's a compose.yaml you can read and change. Nothing runs until you press Start.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: DS.Spacing.m)], spacing: DS.Spacing.m) {
                ForEach(ComposeTemplate.all) { template in
                    let selected = chosen == template
                    Button { chosen = template; name = template.id == "web" ? "my-app" : template.id } label: {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Label(template.title, systemImage: template.systemImage).font(.headline)
                            Text(template.about).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .padding(DS.Spacing.m)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.raised))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                            .strokeBorder(selected ? DS.accent : DS.separator.opacity(0.6), lineWidth: selected ? 2 : 0.5))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            HStack {
                Text("Folder name").foregroundStyle(.secondary)
                TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Text("Opens at \(chosen.opens)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.automatic)
                Button("Choose Where…") { choose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 620)
        .onAppear { chosen = initial; name = initial.id == "web" ? "my-app" : initial.id }
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
