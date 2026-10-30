import Foundation

/// Short descriptions of compose keys and values, the blocks Tab inserts,
/// and whole-service templates. Blocks are written with two-space indents
/// and the key on the first line; `ComposeCompletion.expand` fits them to
/// where they go.
enum ComposeCatalog {
    static let topKeys: [String: String] = [
        "services": String(localized: "The containers this project runs, one entry per service."),
        "networks": String(localized: "Networks services join; services reach each other by name on a shared one."),
        "volumes": String(localized: "Named volumes: data that outlives containers."),
        "name": String(localized: "Project name (default: the folder's name)."),
        "configs": String(localized: "Files mounted into services. Not supported by container."),
        "secrets": String(localized: "Secret files mounted into services. Not supported by container."),
        "include": String(localized: "Other compose files to merge in. Not supported yet."),
    ]

    static let serviceKeys: [String: String] = [
        "image": String(localized: "Image to run, e.g. postgres:17. Pulled if not on this Mac."),
        "build": String(localized: "Build the image from a Dockerfile instead of pulling one."),
        "command": String(localized: "Override the image's command."),
        "entrypoint": String(localized: "Override the image's entrypoint."),
        "environment": String(localized: "Environment variables, as KEY: value."),
        "env_file": String(localized: "Read environment variables from a file."),
        "ports": String(localized: "Publish ports on this Mac, as \"host:container\"."),
        "volumes": String(localized: "Mount named volumes or folders from this Mac."),
        "depends_on": String(localized: "Start after these services; optionally wait until they're healthy."),
        "networks": String(localized: "Networks to join (default: the project's network)."),
        "restart": String(localized: "Restart when it stops: run by Irekobox's background helper."),
        "healthcheck": String(localized: "Command that tells whether the service works; run by the background helper."),
        "container_name": String(localized: "Fixed container name instead of project-service."),
        "working_dir": String(localized: "Working directory inside the container."),
        "user": String(localized: "User (and group) to run as, e.g. \"999:999\"."),
        "labels": String(localized: "Labels on the container."),
        "cpus": String(localized: "CPU limit, e.g. 2."),
        "mem_limit": String(localized: "Memory limit, e.g. 512m or 2g."),
        "read_only": String(localized: "Mount the root filesystem read-only."),
        "init": String(localized: "Run an init process that reaps zombies."),
        "tty": String(localized: "Allocate a terminal."),
        "stdin_open": String(localized: "Keep standard input open."),
        "cap_add": String(localized: "Linux capabilities to add."),
        "cap_drop": String(localized: "Linux capabilities to drop."),
        "dns": String(localized: "DNS servers to use."),
        "platform": String(localized: "Platform to run, e.g. linux/amd64 (via Rosetta)."),
        "shm_size": String(localized: "Size of /dev/shm."),
        "profiles": String(localized: "Start only when one of these profiles is active."),
        "scale": String(localized: "Number of containers to run."),
        "deploy": String(localized: "Resource limits (only resources.limits is used)."),
        "hostname": String(localized: "Partly supported: the hostname is the container name."),
        "expose": String(localized: "Ports other services may use; informational here."),
        "extra_hosts": String(localized: "Extra /etc/hosts entries. Not supported by container."),
        "network_mode": String(localized: "Partly supported: only user-defined networks."),
        "secrets": String(localized: "Secrets to mount. Not supported by container."),
        "configs": String(localized: "Configs to mount. Not supported by container."),
        "logging": String(localized: "Log driver options. Not supported: logs stay in container."),
        "ulimits": String(localized: "Resource limits per process. Not supported by container."),
        "sysctls": String(localized: "Kernel parameters. Not supported by container."),
        "privileged": String(localized: "Full privileges. Not supported by container."),
        "security_opt": String(localized: "Security options. Not supported by container."),
        "pull_policy": String(localized: "When to pull the image."),
        "stop_signal": String(localized: "Signal that stops the container."),
        "stop_grace_period": String(localized: "How long to wait before killing it on stop."),
        "extends": String(localized: "Take settings from another service."),
        "devices": String(localized: "Host devices. Not supported by container."),
        "tmpfs": String(localized: "In-memory mounts."),
        "ipc": String(localized: "IPC namespace. Not supported by container."),
        "pid": String(localized: "PID namespace. Not supported by container."),
        "develop": String(localized: "Compose Watch settings. Not supported yet."),
    ]

    static let nestedKeys: [String: String] = [
        "test": String(localized: "Command to run: [\"CMD\", …] or [\"CMD-SHELL\", \"…\"]; exit 0 means healthy."),
        "interval": String(localized: "Time between checks, e.g. 30s."),
        "timeout": String(localized: "How long one check may take."),
        "retries": String(localized: "Failures in a row before it's unhealthy."),
        "start_period": String(localized: "Grace time after start; failures don't count yet."),
        "start_interval": String(localized: "Time between checks during the start period."),
        "disable": String(localized: "Turn off the image's health check."),
        "context": String(localized: "Folder sent to the build (relative to the compose file)."),
        "dockerfile": String(localized: "Dockerfile to use, relative to the context."),
        "args": String(localized: "Build arguments."),
        "target": String(localized: "Stage of a multi-stage Dockerfile to build."),
        "platforms": String(localized: "Platforms to build for."),
        "tags": String(localized: "Extra tags for the built image."),
        "cache_from": String(localized: "Images to use as build cache."),
        "resources": String(localized: "Resource limits and reservations."),
        "replicas": String(localized: "Number of containers."),
        "restart_policy": String(localized: "Swarm restart policy; use restart instead."),
        "driver": String(localized: "Driver to use."),
        "options": String(localized: "Driver options."),
        "condition": String(localized: "What to wait for before starting."),
        "required": String(localized: "Whether the dependency must exist."),
        "external": String(localized: "Created outside this project: use it, don't create it."),
        "driver_opts": String(localized: "Driver options."),
    ]

    static let values: [String: [String: String]] = [
        "restart": [
            "no": String(localized: "Never restart (default)."),
            "always": String(localized: "Restart whenever it stops, also after Irekobox starts."),
            "on-failure": String(localized: "Restart when it exits with an error."),
            "unless-stopped": String(localized: "Restart unless you stopped it."),
        ],
        "condition": [
            "service_started": String(localized: "Wait until it has started."),
            "service_healthy": String(localized: "Wait until its health check passes."),
            "service_completed_successfully": String(localized: "Wait until it has finished with exit code 0."),
        ],
        "pull_policy": [
            "always": String(localized: "Pull on every start."),
            "missing": String(localized: "Pull only if not on this Mac (default)."),
            "never": String(localized: "Never pull; fail if missing."),
            "build": String(localized: "Build the image."),
        ],
        "platform": ["linux/arm64": String(localized: "Native on Apple silicon."), "linux/amd64": String(localized: "Intel images, through Rosetta.")],
    ]

    /// Blocks Tab inserts for a key.
    static let blocks: [String: String] = [
        "services": "services:\n  app:\n    image: nginx:alpine\n    ports:\n      - \"8080:80\"",
        "networks": "networks:\n  backend:",
        "volumes": "volumes:\n  data:",
        "build": "build:\n  context: .\n  dockerfile: Dockerfile",
        "environment": "environment:\n  KEY: value",
        "ports": "ports:\n  - \"8080:80\"",
        "depends_on": "depends_on:\n  db:\n    condition: service_healthy",
        "healthcheck": "healthcheck:\n  test: [\"CMD-SHELL\", \"wget -qO- http://localhost/ || exit 1\"]\n  interval: 30s\n  timeout: 5s\n  retries: 3\n  start_period: 10s",
        "restart": "restart: unless-stopped",
        "deploy": "deploy:\n  resources:\n    limits:\n      cpus: \"1\"\n      memory: 512M",
        "command": "command: [\"sh\", \"-c\", \"echo ready\"]",
        "labels": "labels:\n  com.example.role: web",
        "env_file": "env_file:\n  - .env",
        "user": "user: \"1000:1000\"",
        "platform": "platform: linux/arm64",
    ]

    struct Template {
        let name: String
        let detail: String
        let block: String

        /// The named volume it uses, to declare at the top level.
        var volume: String? {
            block.components(separatedBy: "\n").lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("- ") && $0.contains("-data:") }
                .map { String($0.dropFirst(2).prefix { $0 != ":" }) }
        }
    }

    /// Whole services, written the way that works on container: named
    /// volumes for data (databases can't own folders mounted from the Mac).
    static let templates: [Template] = [
        Template(name: "postgres", detail: String(localized: "PostgreSQL 17, data in a named volume, healthy when it accepts connections."), block: """
        postgres:
          image: postgres:17
          environment:
            POSTGRES_PASSWORD: postgres
          ports:
            - "5432:5432"
          volumes:
            - postgres-data:/var/lib/postgresql/data
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -U postgres"]
            interval: 10s
            timeout: 5s
            retries: 5
        """),
        Template(name: "mysql", detail: String(localized: "MySQL 8.4, data in a named volume, with a health check."), block: """
        mysql:
          image: mysql:8.4
          environment:
            MYSQL_ROOT_PASSWORD: mysql
          ports:
            - "3306:3306"
          volumes:
            - mysql-data:/var/lib/mysql
          healthcheck:
            test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
            interval: 10s
            timeout: 5s
            retries: 5
        """),
        Template(name: "redis", detail: String(localized: "Redis 7 with append-only persistence and a health check."), block: """
        redis:
          image: redis:7-alpine
          command: redis-server --appendonly yes
          ports:
            - "6379:6379"
          volumes:
            - redis-data:/data
          healthcheck:
            test: ["CMD", "redis-cli", "ping"]
            interval: 10s
            timeout: 5s
            retries: 5
        """),
        Template(name: "mongo", detail: String(localized: "MongoDB 8, data in a named volume."), block: """
        mongo:
          image: mongo:8
          ports:
            - "27017:27017"
          volumes:
            - mongo-data:/data/db
        """),
        Template(name: "nginx", detail: String(localized: "nginx serving ./site on port 8080."), block: """
        nginx:
          image: nginx:alpine
          ports:
            - "8080:80"
          volumes:
            - ./site:/usr/share/nginx/html:ro
        """),
        Template(name: "rabbitmq", detail: String(localized: "RabbitMQ with the management UI on 15672."), block: """
        rabbitmq:
          image: rabbitmq:4-management
          ports:
            - "5672:5672"
            - "15672:15672"
        """),
    ]
}
