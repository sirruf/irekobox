import XCTest
@preconcurrency import XPC
@testable import ContainerKit

/// The apiserver reply holder resolves once and drops its timer with the reply.
final class PendingReplyTests: XCTestCase {
    private let queue = DispatchQueue(label: "pending-reply-tests")

    func testAReplyCancelsTheDeadline() async throws {
        let pending = PendingReply()
        let reply = APIServerConnection.Reply(object: xpc_dictionary_create_empty())
        let received: APIServerConnection.Reply = try await withCheckedThrowingContinuation { continuation in
            pending.install(continuation)
            pending.expire(after: .seconds(30), on: queue, with: EngineError.timedOut)
            XCTAssertTrue(pending.isExpiring)
            pending.resume(with: .success(reply))
        }
        XCTAssertTrue(received.object === reply.object)
        XCTAssertFalse(pending.isExpiring, "nothing stays scheduled after the reply")
        // A late outcome is dropped, not delivered twice.
        pending.resume(with: .failure(EngineError.timedOut))
    }

    func testTheDeadlineFailsAnUnansweredRequest() async {
        let pending = PendingReply()
        do {
            let _: APIServerConnection.Reply = try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                pending.expire(after: .milliseconds(20), on: queue, with: EngineError.timedOut)
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? EngineError, .timedOut)
        }
        XCTAssertFalse(pending.isExpiring)
    }

    func testADeadlineAfterTheOutcomeIsNotScheduled() {
        let pending = PendingReply()
        pending.resume(with: .failure(EngineError.cancelled))   // cancelled before install
        pending.expire(after: .seconds(30), on: queue, with: EngineError.timedOut)
        XCTAssertFalse(pending.isExpiring)
    }
}
