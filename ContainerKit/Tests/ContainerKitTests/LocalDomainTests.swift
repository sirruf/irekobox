import XCTest
@testable import ContainerKit

final class LocalDomainTests: XCTestCase {
    func testDomainFromProperties() {
        XCTAssertEqual(LocalDomain.parse(properties: "[build]\ncpus = 2\n\n[dns]\ndomain = \"test\"\n\n[kernel]\n"), "test")
        XCTAssertNil(LocalDomain.parse(properties: "[dns]\n\n[kernel]\ndomain = \"x\"\n"))
    }

    func testServiceNamesAreDNSLabels() {
        XCTAssertEqual(LocalDomain.serviceName(service: "web", project: "shop", domain: "test"), "web.shop.test")
        XCTAssertEqual(LocalDomain.serviceName(service: "api_v2", project: "My_Shop", domain: "test"), "api-v2.my-shop.test")
        XCTAssertNil(LocalDomain.serviceName(service: "_", project: "shop", domain: "test"))
    }
}
