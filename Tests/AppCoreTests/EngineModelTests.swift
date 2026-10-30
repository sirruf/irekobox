import XCTest
import ContainerKit
import EngineCore
@testable import AppCore

@MainActor
final class EngineModelTests: XCTestCase {

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met in time")
    }

    func testSwitchingSourceMovesInterestsAndData() async throws {
        let localCLI = MockCLI()
        localCLI.responder = { _ in Data(Fixtures.volumes.utf8) }
        let local = EngineStore(engine: CLIEngine(cli: localCLI, stream: CLIStream()))
        let agentCLI = MockCLI()
        agentCLI.responder = { _ in Data(Fixtures.containers.utf8) }
        let agent = EngineStore(engine: CLIEngine(cli: agentCLI, stream: CLIStream()))
        let model = EngineModel(source: local)

        let screen = Task { await model.observe([.containers]) }
        try await eventually { await local.polledResources.contains(.containers) }

        await model.setSource(agent, agentBacked: true)
        XCTAssertTrue(model.isAgentBacked)
        try await eventually { await agent.polledResources.contains(.containers) }
        try await eventually { await !local.polledResources.contains(.containers) }

        await model.refresh([.containers])
        XCTAssertEqual(model.containers.map(\.id), ["web"])

        // Leaving the screen ends the interest on the current source.
        screen.cancel()
        try await eventually { await !agent.polledResources.contains(.containers) }
    }
}
