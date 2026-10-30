import Foundation
import SystemConfiguration
import EngineCore
import os

// Root helper (SMAppService.daemon): keeps /var/run/docker.sock pointing at
// the console user's Irekobox socket while the app asks for it.
// launchd runs it at load, when the request file changes and every 30 s
// (/var/run is emptied at boot); each run does one pass and exits.

let log = Logger(subsystem: "com.irekobox", category: "socket-link")

func consoleHome() -> String? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid != 0, let entry = getpwuid(uid) else { return nil }
    return String(cString: entry.pointee.pw_dir)
}

func loadState() -> SocketLink.State {
    guard let data = FileManager.default.contents(atPath: SocketLink.statePath),
          let state = try? JSONDecoder().decode(SocketLink.State.self, from: data) else { return SocketLink.State() }
    return state
}

func saveState(_ state: SocketLink.State) {
    let url = URL(fileURLWithPath: SocketLink.statePath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(state).write(to: url, options: .atomic)
}

guard let home = consoleHome() else {
    log.info("no console user; nothing to do")
    exit(0)
}
let target = SocketLink.target(home: home)
let current = SocketLink.readLink(SocketLink.linkPath)
let live = current.map { FileManager.default.fileExists(atPath: $0) } ?? false
let before = loadState()
let (action, after) = SocketLink.plan(wanted: SocketLink.requested(), target: target, current: current,
                                      currentIsLive: live, state: before)
do {
    switch action {
    case .none:
        break
    case .link(let destination):
        try SocketLink.makeLink(SocketLink.linkPath, to: destination)
        log.info("\(SocketLink.linkPath, privacy: .public) -> \(destination, privacy: .public)")
    case .remove:
        unlink(SocketLink.linkPath)
        log.info("removed \(SocketLink.linkPath, privacy: .public)")
    }
    if after != before { saveState(after) }
} catch {
    log.error("relinking failed: \(String(describing: error), privacy: .public)")
    exit(1)
}
