import Foundation
import ContainerKit
import DockerAPIKit

// Development runner: serves the Docker API on a socket against the live
// engine, for trying real clients before the agent hosts it.
//   swift run DockerAPIDev [/path/to/docker.sock]
//   DOCKER_HOST=unix:///path/to/docker.sock docker version
//   CONTAINER_CLI=/path/to/container swift run DockerAPIDev   (another CLI)

let path = CommandLine.arguments.dropFirst().first
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".irekobox/docker.sock").path
let cli = ProcessInfo.processInfo.environment["CONTAINER_CLI"] ?? ContainerCLI.defaultBinaryPath
let engine = XPCEngine(fallback: CLIEngine(cli: ContainerCLI(binaryPath: cli), stream: CLIStream(binaryPath: cli)))
let api = DockerEngineAPI(backend: EngineBackend(engine: engine), host: DockerHostInfo(appVersion: "dev"), socketPath: path,
                          exitsFile: URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "exits.json"))
Task {
    await api.supervisor.start()
    await api.exits.start()
    await api.hosts.start()
    await api.health.start()
}
let server = DockerAPIServer(socketPath: path, router: api.router)
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("Can't listen on \(path): \(error)\n".utf8))
    exit(1)
}
print("Docker API on unix://\(path) — Ctrl-C to stop")
signal(SIGINT, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
stop.setEventHandler {
    server.stop()
    exit(0)
}
stop.resume()
dispatchMain()
