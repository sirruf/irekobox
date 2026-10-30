import XCTest
@testable import AppCore

@MainActor
final class ContainerInstallerTests: XCTestCase {

    // `pkgutil --check-signature` of container-1.6.1-installer-signed.pkg.
    private let appleReport = """
    Package "container-1.6.1-installer-signed.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Signed with a trusted timestamp on: 2026-10-23 23:39:42 +0000
       Certificate Chain:
        1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)
           Expires: 2030-06-04 16:44:29 +0000
        2. Developer ID Certification Authority
           Expires: 2031-09-17 00:00:00 +0000
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
    """

    func testTrustsOnlyApplesNotarizedPackage() {
        XCTAssertTrue(ContainerInstaller.isTrusted(signatureReport: appleReport))

        let otherTeam = appleReport.replacingOccurrences(of: "Apple Inc. - Containerization (UPBK2H6LZM)",
                                                         with: "Apple Inc. - Containerization (ABCDE12345)")
        XCTAssertFalse(ContainerInstaller.isTrusted(signatureReport: otherTeam), "same name, another team")

        let impostor = appleReport.replacingOccurrences(of: "1. Developer ID Installer: Apple Inc. - Containerization",
                                                        with: "1. Developer ID Installer: Someone Else")
        XCTAssertFalse(ContainerInstaller.isTrusted(signatureReport: impostor))

        let notNotarized = appleReport.replacingOccurrences(of: "   Notarization: trusted by the Apple notary service\n", with: "")
        XCTAssertFalse(ContainerInstaller.isTrusted(signatureReport: notNotarized))

        XCTAssertFalse(ContainerInstaller.isTrusted(signatureReport: "Package \"x.pkg\":\n   Status: no signature"))
    }

    func testVersionGate() {
        XCTAssertTrue(ContainerInstaller.isSupported(versionOutput: "container CLI version 1.6.1 (build: release, commit: aa8d76b)"))
        XCTAssertTrue(ContainerInstaller.isSupported(versionOutput: "container CLI version 1.10.0"))
        XCTAssertFalse(ContainerInstaller.isSupported(versionOutput: "container CLI version 1.0.0 (build: release)"))
        XCTAssertFalse(ContainerInstaller.isSupported(versionOutput: "garbage"))
    }

    func testPackageURL() {
        XCTAssertEqual(ContainerInstaller.packageURL(version: "1.6.1").absoluteString,
                       "https://github.com/apple/container/releases/download/1.6.1/container-1.6.1-installer-signed.pkg")
    }
}
