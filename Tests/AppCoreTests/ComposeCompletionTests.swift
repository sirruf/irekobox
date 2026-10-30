import XCTest
@testable import AppCore

final class ComposeCompletionTests: XCTestCase {
    private let file = """
    services:
      web:
        image: nginx
        depends_on: [api]
        networks:
          - front
      api:
        image: node
      db:
        image: postgres
    networks:
      front:
      back:
    """

    /// Suggestions with the cursor where `|` is.
    private func suggest(_ text: String, images: [String] = []) -> [String] {
        let cursor = (text as NSString).range(of: "|").location
        let clean = text.replacingOccurrences(of: "|", with: "")
        return ComposeCompletion.suggest(in: clean, at: cursor, images: images)?.items.map(\.label) ?? []
    }

    func testKeysByLevel() {
        XCTAssertEqual(suggest("ser|"), ["services"])
        XCTAssertEqual(suggest("services:\n  web:\n    ima|"), ["image"])
        XCTAssertTrue(suggest("services:\n  web:\n    |").starts(with: ["image", "build"]))
        XCTAssertEqual(suggest("services:\n  web:\n    healthcheck:\n      ret|"), ["retries"])
        XCTAssertEqual(suggest("services:\n  web:\n    depends_on:\n      db:\n        con|"), ["condition"])
        XCTAssertEqual(suggest("services:\n  we|"), [], "service names are the user's own")
        XCTAssertEqual(suggest("services:\n  re|"), ["redis"], "or a template")
    }

    func testValues() {
        XCTAssertEqual(suggest("services:\n  web:\n    restart: un|"), ["unless-stopped"])
        XCTAssertEqual(suggest("services:\n  web:\n    image: ng|", images: ["nginx:alpine", "node:22"]), ["nginx:alpine"])
        XCTAssertEqual(suggest("services:\n  w:\n    depends_on:\n      d:\n        condition: service_h|"),
                       ["service_healthy"])
    }

    func testNamesFromTheFile() {
        let dependsInline = file.replacingOccurrences(of: "depends_on: [api]", with: "depends_on: [api, |]")
        XCTAssertEqual(suggest(dependsInline), ["api", "db"], "other services, not itself")
        let networkItem = file.replacingOccurrences(of: "      - front", with: "      - b|")
        XCTAssertEqual(suggest(networkItem), ["back"])
        XCTAssertEqual(ComposeCompletion.names(under: "services", in: file), ["web", "api", "db"])
    }

    func testNothingInCommentsOrFinishedWords() {
        XCTAssertEqual(suggest("# ima|"), [])
        XCTAssertEqual(suggest("services:\n  web:\n    restart: always|"), [])
    }

    /// Every key comes with a description; keys with a block offer it.
    func testDescriptionsAndBlocks() throws {
        let items = try XCTUnwrap(ComposeCompletion.suggest(in: "services:\n  web:\n    hea", at: 23)?.items)
        let health = try XCTUnwrap(items.first)
        XCTAssertEqual(health.label, "healthcheck")
        XCTAssertEqual(health.insert, "healthcheck: ")
        XCTAssertFalse(health.detail.isEmpty)
        XCTAssertNotNil(health.block)
        for key in ComposeCompletion.serviceKeys {
            XCTAssertNotNil(ComposeCatalog.serviceKeys[key], "\(key) has no description")
        }
    }

    /// Blocks follow the line's column and the file's indent step.
    func testExpandFitsIndentation() {
        let block = "depends_on:\n  db:\n    condition: service_healthy"
        XCTAssertEqual(ComposeCompletion.expand(block, column: 4, unit: 2),
                       "depends_on:\n      db:\n        condition: service_healthy")
        XCTAssertEqual(ComposeCompletion.expand(block, column: 8, unit: 4),
                       "depends_on:\n            db:\n                condition: service_healthy")
        XCTAssertEqual(ComposeCompletion.indentUnit("services:\n    web:\n"), 4)
    }

    /// A service's `image:` value is where Docker Hub is searched, tag included.
    func testImageValue() {
        func image(_ text: String) -> String? {
            let cursor = (text as NSString).range(of: "|").location
            return ComposeCompletion.imageValue(in: text.replacingOccurrences(of: "|", with: ""), at: cursor)?.word
        }
        XCTAssertEqual(image("services:\n  db:\n    image: postg|\n"), "postg")
        XCTAssertEqual(image("services:\n  db:\n    image: postgres:17|\n"), "postgres:17")
        XCTAssertNil(image("services:\n  db:\n    command: postg|\n"))
        XCTAssertNil(image("x-image:\n  image: postg|\n"))
    }

    /// A template's named volume is declared at the top level once.
    func testTemplateVolumeDeclaration() throws {
        let postgres = try XCTUnwrap(ComposeCatalog.templates.first { $0.name == "postgres" })
        XCTAssertEqual(postgres.volume, "postgres-data")
        let none = "services:\n  db:\n    image: x\n"
        let add = try XCTUnwrap(ComposeCompletion.volumeDeclaration("postgres-data", in: none))
        XCTAssertEqual(add.offset, (none as NSString).length)
        XCTAssertEqual(add.insert, "volumes:\n  postgres-data:\n")
        let existing = "services:\n  db:\n    image: x\nvolumes:\n  other:\n"
        let into = try XCTUnwrap(ComposeCompletion.volumeDeclaration("postgres-data", in: existing))
        XCTAssertEqual((existing as NSString).replacingCharacters(in: NSRange(location: into.offset, length: 0), with: into.insert),
                       "services:\n  db:\n    image: x\nvolumes:\n  postgres-data:\n  other:\n")
        XCTAssertNil(ComposeCompletion.volumeDeclaration("other", in: existing))
    }
}
