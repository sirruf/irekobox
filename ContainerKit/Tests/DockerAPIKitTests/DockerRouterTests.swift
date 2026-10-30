import XCTest
@testable import DockerAPIKit

final class DockerRouterTests: XCTestCase {

    private func router() -> DockerRouter {
        var router = DockerRouter()
        router.add("GET", "/containers/{id}/json") { request in
            .text("\(request.parameters["id"] ?? "")@\(request.apiVersion)")
        }
        router.add("GET", "/_ping") { _ in .text("OK") }
        return router
    }

    private func body(_ response: HTTPResponse) -> String {
        if case .data(let data) = response.body { return String(decoding: data, as: UTF8.self) }
        return ""
    }

    func testVersionPrefixAndParameters() async {
        let unversioned = await router().handle(HTTPRequest(method: "GET", target: "/containers/web/json"))
        XCTAssertEqual(body(unversioned), "web@1.56")
        let versioned = await router().handle(HTTPRequest(method: "GET", target: "/v1.32/containers/web/json?size=1"))
        XCTAssertEqual(versioned.status, 200)
        XCTAssertEqual(body(versioned), "web@1.32")
    }

    func testVersionOutOfRange() async {
        let old = await router().handle(HTTPRequest(method: "GET", target: "/v1.12/_ping"))
        XCTAssertEqual(old.status, 400)
        XCTAssertTrue(body(old).contains("too old"))
        let new = await router().handle(HTTPRequest(method: "GET", target: "/v1.99/_ping"))
        XCTAssertEqual(new.status, 400)
        XCTAssertTrue(body(new).contains("too new"))
    }

    func testHeadFallsBackToGetAndUnknownIs404() async {
        let head = await router().handle(HTTPRequest(method: "HEAD", target: "/_ping"))
        XCTAssertEqual(head.status, 200)
        let missing = await router().handle(HTTPRequest(method: "GET", target: "/nope"))
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(body(missing), #"{"message":"page not found"}"# + "\n")
        let wrongMethod = await router().handle(HTTPRequest(method: "DELETE", target: "/_ping"))
        XCTAssertEqual(wrongMethod.status, 404)
    }

    func testWideParametersTakeSeveralSegments() async {
        var router = DockerRouter()
        router.add("GET", "/images/{name*}/json") { request in .text(request.parameters["name"] ?? "") }
        router.add("DELETE", "/images/{name*}") { request in .text("rm " + (request.parameters["name"] ?? "")) }
        func body(_ response: HTTPResponse) -> String {
            if case .data(let data) = response.body { return String(decoding: data, as: UTF8.self) }
            return ""
        }
        let simple = await router.handle(HTTPRequest(method: "GET", target: "/images/alpine/json"))
        XCTAssertEqual(body(simple), "alpine")
        let nested = await router.handle(HTTPRequest(method: "GET", target: "/v1.44/images/ghcr.io/apple/x:1/json"))
        XCTAssertEqual(body(nested), "ghcr.io/apple/x:1")
        let removed = await router.handle(HTTPRequest(method: "DELETE", target: "/images/ib-test/alpine:v1"))
        XCTAssertEqual(body(removed), "rm ib-test/alpine:v1")
        let none = await router.handle(HTTPRequest(method: "GET", target: "/images/json"))
        XCTAssertEqual(none.status, 404, "the wide segment needs at least one")
    }
}
