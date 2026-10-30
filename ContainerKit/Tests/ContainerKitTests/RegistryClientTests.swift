import XCTest
@testable import ContainerKit

final class RegistryClientTests: XCTestCase {
    func testSplitsReferences() {
        XCTAssertTrue(RegistryClient.split("docker.io/library/redis:7-alpine")! == ("registry-1.docker.io", "library/redis", "7-alpine"))
        XCTAssertTrue(RegistryClient.split("ghcr.io/apple/x")! == ("ghcr.io", "apple/x", "latest"))
        XCTAssertTrue(RegistryClient.split("localhost:5000/team/app:v2")! == ("localhost:5000", "team/app", "v2"))
        XCTAssertNil(RegistryClient.split("docker.io/library/redis@sha256:abc"))
        XCTAssertNil(RegistryClient.split("redis:7"), "unqualified: not what container stores")
    }

    func testAnonymousTokenFlow() async throws {
        let seen = Recorder()
        let digest = RegistryClient { request in
            seen.add("\(request.httpMethod ?? "GET") \(request.url!.absoluteString) \(request.value(forHTTPHeaderField: "Authorization") ?? "")")
            let url = request.url!
            if url.host == "auth.docker.io" {
                return (Data(#"{"token":"t0k"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.value(forHTTPHeaderField: "Authorization") == nil {
                return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: [
                    "WWW-Authenticate": #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/redis:pull""#])!)
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Docker-Content-Digest": "sha256:new"])!)
        }
        let value = try await digest.digest(of: "docker.io/library/redis:7-alpine")
        XCTAssertEqual(value, "sha256:new")
        XCTAssertEqual(seen.all.count, 3)
        XCTAssertTrue(seen.all[1].contains("service=registry.docker.io") && seen.all[1].contains("scope=repository:library/redis:pull"))
        XCTAssertTrue(seen.all[2].hasSuffix("Bearer t0k"))
    }

    /// An index goes to the arm64 manifest, then its config blob: the
    /// ports and volumes the image declares, without pulling it.
    func testConfigFromIndex() async throws {
        let client = RegistryClient { request in
            let url = request.url!
            func ok(_ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            switch url.path {
            case "/v2/library/postgres/manifests/17":
                return ok(#"{"manifests":[{"digest":"sha256:amd","platform":{"architecture":"amd64","os":"linux"}},{"digest":"sha256:arm","platform":{"architecture":"arm64","os":"linux"}}]}"#)
            case "/v2/library/postgres/manifests/sha256:arm":
                return ok(#"{"config":{"digest":"sha256:cfg"}}"#)
            case "/v2/library/postgres/blobs/sha256:cfg":
                return ok(#"{"architecture":"arm64","config":{"ExposedPorts":{"5432/tcp":{}},"Volumes":{"/var/lib/postgresql/data":{}},"Env":["PGDATA=/var/lib/postgresql/data"]}}"#)
            default:
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        let config = try await client.config(of: "docker.io/library/postgres:17")
        XCTAssertEqual(config?.config?.ExposedPorts?.keys.sorted(), ["5432/tcp"])
        XCTAssertEqual(config?.config?.Volumes?.keys.sorted(), ["/var/lib/postgresql/data"])
    }

    /// The real Docker Hub: IREKOBOX_LIVE_REGISTRY=1
    func testLiveDockerHub() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_REGISTRY"] == "1", "live only")
        let value = try await RegistryClient().digest(of: "docker.io/library/alpine:latest")
        XCTAssertTrue(value?.hasPrefix("sha256:") == true, "\(String(describing: value))")
        print("alpine:latest on Docker Hub:", value ?? "nil")
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

final class RegistryTagsTests: XCTestCase {
    func testRanksTags() {
        let tags = ["alpine", "24", "25.1-alpine", "latest", "25", "25-alpine", "25.1", "9", "lts", "24.11.1"]
        XCTAssertEqual(RegistryClient.ranked(tags),
                       ["latest", "25", "25-alpine", "25.1", "25.1-alpine", "24", "24.11.1", "9", "lts", "alpine"])
    }

    func testNextPageLink() {
        let base = URL(string: "https://ghcr.io/v2/a/b/tags/list?n=2")!
        XCTAssertEqual(RegistryClient.nextPage(#"</v2/a/b/tags/list?n=2&last=x>; rel="next""#, relativeTo: base)?.absoluteString,
                       "https://ghcr.io/v2/a/b/tags/list?n=2&last=x")
        XCTAssertNil(RegistryClient.nextPage(#"</v2/a/b/tags/list>; rel="prev""#, relativeTo: base))
    }

    func testTagsWithLoginAndPages() async throws {
        let seen = Recorder()
        let client = RegistryClient { request in
            let url = request.url!
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            seen.add("\(url.absoluteString) \(auth)")
            if url.host == "auth.example.com" {
                return (Data(#"{"token":"t0k"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            guard auth == "Bearer t0k" else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: [
                    "WWW-Authenticate": #"Bearer realm="https://auth.example.com/token",service="example""#])!)
            }
            if url.query?.contains("last=b") == true {
                return (Data(#"{"tags":["c"]}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"{"tags":["a","b"]}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Link": #"</v2/team/app/tags/list?n=2&last=b>; rel="next""#])!)
        }
        let tags = try await client.tags(registry: "registry.example.com", repository: "team/app",
                                         credentials: .init(username: "me", password: "pw"))
        XCTAssertEqual(tags, ["a", "b", "c"])
        let tokenRequest = seen.all.first { $0.hasPrefix("https://auth.example.com") }!
        XCTAssertTrue(tokenRequest.contains("scope=repository:team/app:pull"))
        XCTAssertTrue(tokenRequest.hasSuffix("Basic " + Data("me:pw".utf8).base64EncodedString()))
    }

    func testPrivateRepositoryError() async {
        let client = RegistryClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await client.tags(registry: "docker.io", repository: "me/secret")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RegistryClient.RegistryError, .unauthorized("me/secret"))
        }
    }

    /// The real Docker Hub: IREKOBOX_LIVE_REGISTRY=1
    func testLiveTags() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_REGISTRY"] == "1", "live only")
        let tags = try await RegistryClient().tags(registry: "docker.io", repository: "library/node")
        XCTAssertGreaterThan(tags.count, 1000)
        print("node tags:", tags.count, Array(tags.prefix(8)))
        let search = try await DockerHubSearch.search("postg", 5)
        XCTAssertEqual(search.first?.name, "postgres")
    }
}
