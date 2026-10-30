import XCTest
import ContainerKit
@testable import AppCore

@MainActor
final class ImageUpdateCheckTests: XCTestCase {
    private func image(_ reference: String, digest: String) throws -> ContainerImage {
        try JSONDecoder().decode(ContainerImage.self, from: Data(#"""
        {"id":"x","configuration":{"name":"\#(reference)","descriptor":{"digest":"\#(digest)","mediaType":"m","size":1}}}
        """#.utf8))
    }

    private func container(_ name: String, image: String) throws -> Container {
        try JSONDecoder().decode(Container.self, from: Data(#"""
        {"id":"\#(name)","status":{"state":"running","networks":[]},
         "configuration":{"id":"\#(name)","image":{"reference":"\#(image)","descriptor":{"digest":"d","mediaType":"m","size":1}},
           "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[],
           "initProcess":{"executable":"sh","arguments":[],"workingDirectory":"/","environment":[]},
           "labels":{},"creationDate":"2026-10-26T00:00:00Z","readOnly":false,"runtimeHandler":"x","rosetta":false}}
        """#.utf8))
    }

    func testFindsNewerTagsInUseAndNotifiesOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ib-img-\(UUID().uuidString)"))
        let remote = ["docker.io/library/redis:7-alpine": "sha256:new", "docker.io/library/nginx:alpine": "sha256:same"]
        let registry = RegistryClient { request in
            let path = request.url!.path
            let reference = path.contains("redis") ? "docker.io/library/redis:7-alpine" : "docker.io/library/nginx:alpine"
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                            headerFields: ["Docker-Content-Digest": remote[reference]!])!)
        }
        let check = ImageUpdateCheck(registry: registry, defaults: defaults)
        var notified: [String] = []
        check.onNewUpdate = { notified.append($0) }
        let redis = try image("docker.io/library/redis:7-alpine", digest: "sha256:old")
        let images = [redis, try image("docker.io/library/nginx:alpine", digest: "sha256:same"),
                      try image("docker.io/library/unused:1", digest: "sha256:x")]
        let containers = [try container("cache", image: redis.reference), try container("web", image: "docker.io/library/nginx:alpine")]

        await check.checkIfDue(images: images, containers: containers)
        XCTAssertEqual(check.updates, ["docker.io/library/redis:7-alpine": "sha256:new"])
        XCTAssertTrue(check.update(for: redis))
        XCTAssertEqual(notified, ["docker.io/library/redis:7-alpine"])

        await check.checkIfDue(images: images, containers: containers, force: true)
        XCTAssertEqual(notified.count, 1, "the same published digest is told once")

        check.pulled(try image(redis.reference, digest: "sha256:new"))
        XCTAssertTrue(check.updates.isEmpty)
    }
}
