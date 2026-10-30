import XCTest
import ContainerKit
import SwiftUI
@testable import AppCore

/// Renders views that are hard to reach on screen (the menu-bar popover) to
/// PNGs for a look. Runs only with SNAPSHOT_DIR set, against the live engine.
@MainActor
final class SnapshotTests: XCTestCase {
    func testMenuBarSnapshot() async throws {
        let folder = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ""
        try XCTSkipIf(folder.isEmpty, "set SNAPSHOT_DIR to render")
        let app = AppState()
        try await Task.sleep(for: .seconds(8))
        let view = MenuBarView().environment(app).frame(width: 340).background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(6))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame.size = CGSize(width: 340, height: max(200, size.height))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(filePath: folder).appending(path: "menubar.png"))
    }

    func testEngineStoppedSnapshot() async throws {
        let folder = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ""
        try XCTSkipIf(folder.isEmpty, "set SNAPSHOT_DIR to render")
        let app = AppState()
        let view = ServiceGateView().environment(app).frame(width: 760, height: 460)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 460)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(filePath: folder).appending(path: "stopped.png"))
    }

    /// Sheets and pop-ups from the Sheets board, rendered one by one.
    func testSheetsSnapshots() async throws {
        let folder = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? ""
        try XCTSkipIf(folder.isEmpty, "set SNAPSHOT_DIR to render")
        let app = AppState()
        let conflict = PortInUse(container: "shop-web-1", port: 8080, command: "node", pid: 4182, free: 8081)
        try await render(ProblemToast(problem: Problem.portInUse(conflict, app: app)) {}.padding(20), "problem", folder)
        let port = PortLink(.init(containerPort: 80, hostPort: 8080, hostAddress: "0.0.0.0", proto: "tcp", count: 1))
        try await render(PortPopoverPreview(port: port), "port", folder)
        let clusters = ClustersModel(cli: app.cli, stream: CLIStream(binaryPath: "/usr/local/bin/container"))
        var sheet = RunAppSheet(cluster: "dev", nodeAddress: nil, model: ClusterModel(name: "dev", node: "dev", cli: app.cli),
                                clusters: clusters, onEditYAML: { _ in })
        sheet.startingAt = (.copies, "nginx:alpine")
        try await render(sheet.environment(app), "runapp", folder)
        try await render(NewClusterSheet(model: clusters), "newcluster", folder)
        try await render(ApplyYAMLSheet(cluster: "dev", model: ClusterModel(name: "dev", node: "dev", cli: app.cli), text: ""),
                         "applyyaml", folder)
        try await render(NewMachineSheet(model: MachinesModel(cli: app.cli), onCreated: { _ in })
            .environment(app), "newmachine", folder)
    }

    private func render(_ view: some View, _ name: String, _ folder: String) async throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(filePath: folder).appending(path: "\(name).png"))
    }
}
