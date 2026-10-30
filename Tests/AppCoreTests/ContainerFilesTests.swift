import XCTest
import ContainerKit
@testable import AppCore

final class ContainerFilesTests: XCTestCase {

    // Real busybox output from nginx:alpine, plus a name containing "|".
    private let listing = """
    regular file|1077|1792605285|-rw-r--r--|/etc/nginx/fastcgi.conf
    directory|4096|1792995805|drwxr-xr-x|/etc/nginx/conf.d
    symbolic link|22|1792624379|lrwxrwxrwx|/etc/nginx/modules
    regular empty file|0|1792605285|-rw-r--r--|/etc/nginx/a|b.conf
    garbage line
    """

    func testParsesStatOutputFoldersFirst() throws {
        let files = ContainerFiles.parse(listing)
        XCTAssertEqual(files.map(\.name), ["conf.d", "a|b.conf", "fastcgi.conf", "modules"])
        let conf = try XCTUnwrap(files.first { $0.name == "fastcgi.conf" })
        XCTAssertEqual(conf.kind, .file)
        XCTAssertEqual(conf.size, 1077)
        XCTAssertEqual(conf.permissions, "-rw-r--r--")
        XCTAssertEqual(conf.modified, Date(timeIntervalSince1970: 1792605285))
        XCTAssertEqual(files.first { $0.name == "modules" }?.kind, .link)
        XCTAssertEqual(files.first { $0.name == "a|b.conf" }?.kind, .file)
    }

    func testPathHelpers() {
        XCTAssertEqual(ContainerFiles.ancestors(of: "/etc/nginx"), ["/", "/etc", "/etc/nginx"])
        XCTAssertEqual(ContainerFiles.ancestors(of: "/"), ["/"])
        XCTAssertEqual(ContainerFiles.parent(of: "/etc/nginx"), "/etc")
        XCTAssertEqual(ContainerFiles.parent(of: "/etc"), "/")
    }

    func testListCommandIsPortable() {
        XCTAssertEqual(ContainerFiles.listCommand("/srv"),
                       ["find", "/srv", "-mindepth", "1", "-maxdepth", "1",
                        "-exec", "stat", "-c", "%F|%s|%Y|%A|%n", "{}", "+"])
    }

    func testDownloadsNeverOverwrite() {
        let folder = URL(filePath: "/Downloads")
        let taken: Set<String> = ["/Downloads/nginx.conf", "/Downloads/nginx 2.conf", "/Downloads/conf.d"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        XCTAssertEqual(ContainerFiles.unusedURL(for: "nginx.conf", in: folder, exists: exists).lastPathComponent, "nginx 3.conf")
        XCTAssertEqual(ContainerFiles.unusedURL(for: "conf.d", in: folder, exists: exists).lastPathComponent, "conf 2.d")
        XCTAssertEqual(ContainerFiles.unusedURL(for: "Makefile", in: folder, exists: exists).lastPathComponent, "Makefile")
    }
}

final class ContainerFilesMountTests: XCTestCase {
    private func mounts() throws -> [Container.Mount] {
        let json = """
        [{"destination": "/usr/share/nginx/html", "source": "/Users/me/site", "options": ["ro"]},
         {"destination": "/var/lib/data", "source": "/x", "type": {"volume": {"name": "pgdata"}}},
         {"destination": "/usr/share/nginx/html/assets", "source": "/Users/me/assets"}]
        """
        return try JSONDecoder().decode([Container.Mount].self, from: Data(json.utf8))
    }

    func testDeepestMountContainingAPath() throws {
        let all = try mounts()
        XCTAssertEqual(ContainerFiles.mount(containing: "/usr/share/nginx/html", in: all)?.source, "/Users/me/site")
        XCTAssertEqual(ContainerFiles.mount(containing: "/usr/share/nginx/html/assets/img", in: all)?.source,
                       "/Users/me/assets")
        XCTAssertEqual(ContainerFiles.mount(containing: "/var/lib/data/base", in: all)?.volumeName, "pgdata")
        XCTAssertNil(ContainerFiles.mount(containing: "/usr/share/nginx/htmlx", in: all))
        XCTAssertNil(ContainerFiles.mount(containing: "/", in: all))
    }

    func testPreviewText() {
        XCTAssertEqual(ContainerFiles.previewText(Data("server {\n}".utf8)), "server {\n}")
        XCTAssertNil(ContainerFiles.previewText(Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01])), "binary")
        // "café" cut inside the last letter still reads.
        let cut = Data("naïve café".utf8).dropLast()
        XCTAssertEqual(ContainerFiles.previewText(cut), "naïve caf")
    }
}
