import XCTest
import ContainerKit
@testable import AppCore

@MainActor
final class BuildViewModelTests: XCTestCase {
    private func makeVM() -> BuildViewModel {
        BuildViewModel(engine: CLIEngine(cli: MockCLI(), stream: CLIStream()))
    }

    func testStageAndStepParsing() {
        let vm = makeVM()
        vm.append("#5 [linux/arm64 1/3] RUN echo step-one")
        XCTAssertEqual(vm.step, 1)
        XCTAssertEqual(vm.total, 3)
        XCTAssertEqual(vm.currentStage, "RUN echo step-one")
        XCTAssertEqual(vm.fraction ?? 0, 1.0 / 3.0, accuracy: 0.001)

        vm.append("#6 [linux/arm64 2/3] RUN echo step-two")
        XCTAssertEqual(vm.step, 2)

        vm.append("#7 exporting to oci image format")
        XCTAssertEqual(vm.currentStage, "exporting image")
    }

    func testReferenceComposition() {
        let vm = makeVM()
        vm.imageName = "registry.example.com/app"
        vm.tag = "1.2"
        XCTAssertEqual(vm.reference, "registry.example.com/app:1.2")
        XCTAssertTrue(vm.canBuild == false) // no context yet
        vm.contextPath = "/tmp/ctx"
        XCTAssertTrue(vm.canBuild)
    }

    func testEmptyTagFallsBackToNameOnly() {
        let vm = makeVM()
        vm.imageName = "app"
        vm.tag = ""
        XCTAssertEqual(vm.reference, "app")
    }
}
