import XCTest
@testable import EngineCore

/// The agent call holder resolves once and drops its timer with the reply.
final class OnceTests: XCTestCase {
    func testAReplyCancelsTheDeadline() async throws {
        let once = Once<Int>()
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            once.install(continuation)
            once.expire(after: .seconds(30), with: AgentClient.ClientError.timedOut)
            XCTAssertTrue(once.isExpiring)
            once.resume(.success(7))
        }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(once.isExpiring, "nothing stays scheduled after the reply")
        once.resume(.failure(AgentClient.ClientError.timedOut))   // dropped
    }

    func testTheDeadlineFailsAnUnansweredCall() async {
        let once = Once<Int>()
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                once.expire(after: .milliseconds(20), with: AgentClient.ClientError.timedOut)
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? AgentClient.ClientError, .timedOut)
        }
        XCTAssertFalse(once.isExpiring)
    }

    func testADeadlineAfterTheOutcomeIsNotScheduled() {
        let once = Once<Int>()
        once.resume(.failure(AgentClient.ClientError.unreachable("gone")))
        once.expire(after: .seconds(30), with: AgentClient.ClientError.timedOut)
        XCTAssertFalse(once.isExpiring)
    }
}
