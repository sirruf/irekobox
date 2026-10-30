import XCTest
import Darwin
@testable import DockerAPIKit

final class SocketConnectionTests: XCTestCase {

    func testRepeatedReadsKeepQueuedBytesIndependent() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw XCTSkip("socketpair unavailable: \(errno)")
        }
        let sender = SocketConnection(fd: descriptors[0])
        let receiver = SocketConnection(fd: descriptors[1])
        defer { sender.close(); receiver.close() }
        let payload = (0..<8).reduce(into: Data()) { data, index in
            data.append(Data(repeating: UInt8(index), count: 128 << 10))
        }
        let writer = Task {
            try await sender.write(payload)
            sender.closeWrite()
        }
        try await writer.value
        var received = Data()
        while let chunk = await receiver.reader.next() { received.append(chunk) }
        XCTAssertEqual(received, payload)
    }
}
