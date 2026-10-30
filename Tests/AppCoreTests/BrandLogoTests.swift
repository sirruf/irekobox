import XCTest
import SwiftUI
import AppKit
@testable import AppCore

@MainActor
final class BrandLogoTests: XCTestCase {
    func testRendersAndDumpsPNG() throws {
        let renderer = ImageRenderer(content: BrandLogo(size: 256))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/brandlogo.png"))
        }
    }
}
