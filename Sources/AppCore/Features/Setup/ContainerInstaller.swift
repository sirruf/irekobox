import Foundation
import Observation
import AppKit
import Security

/// Gets Apple's `container` onto the Mac: downloads the signed installer
/// package of a release, checks it really is Apple's and notarized, then hands
/// it to macOS Installer, which asks for the administrator password itself.
@MainActor
@Observable
final class ContainerInstaller {
    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double?)
        case verifying
        /// Installer is open; waiting for the user to finish it.
        case installing
        case failed(String)
    }

    /// The oldest `container` this app supports.
    static let minimumVersion = "1.6.0"
    /// Apple's Developer ID team for the Containerization packages.
    nonisolated static let appleTeamID = "UPBK2H6LZM"

    private(set) var phase: Phase = .idle

    /// `container-<version>-installer-signed.pkg` on the release's page.
    static func packageURL(version: String) -> URL {
        URL(string: "https://github.com/apple/container/releases/download/\(version)/container-\(version)-installer-signed.pkg")!
    }

    /// Whether `container --version` output ("container CLI version 1.6.1 (build: …)")
    /// is at least the minimum. Unparseable output counts as too old.
    static func isSupported(versionOutput: String) -> Bool {
        guard let version = parseVersion(versionOutput) else { return false }
        return ContainerUpdateCheck.compare(version, minimumVersion) != .orderedAscending
    }

    static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// `pkgutil --check-signature` output of a package Apple signed for
    /// distribution, notarized, with the Containerization team's certificate.
    static func isTrusted(signatureReport report: String) -> Bool {
        let lines = report.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let signed = lines.contains("Status: signed by a developer certificate issued by Apple for distribution")
        let notarized = lines.contains { $0.hasPrefix("Notarization: trusted by the Apple notary service") }
        let leaf = lines.first { $0.hasPrefix("1. ") } ?? ""
        return signed && notarized
            && leaf.hasPrefix("1. Developer ID Installer: Apple Inc.")
            && leaf.hasSuffix("(\(appleTeamID))")
    }

    /// Whether `path` is Apple's `container` CLI, safe to run as root: signed
    /// by the Containerization team, and it and its folder owned by root and
    /// writable by no one else (so it can't be swapped after the check).
    nonisolated static func isTrustedBinary(at path: String) -> Bool {
        guard !path.contains(where: { "'\"\\`$".contains($0) }) else { return false }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        for item in [url.path, url.deletingLastPathComponent().path] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: item),
                  (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  mode & 0o022 == 0 else { return false }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "identifier \"com.apple.container.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"\(appleTeamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    func install(version: String) async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Irekobox-Install/\(UUID().uuidString)")
        let package = folder.appending(path: "container-\(version)-installer-signed.pkg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            phase = .downloading(fraction: nil)
            try await download(Self.packageURL(version: version), to: package)

            phase = .verifying
            let report = try await Self.run("/usr/sbin/pkgutil", ["--check-signature", package.path])
            guard Self.isTrusted(signatureReport: report) else {
                try? FileManager.default.removeItem(at: package)
                phase = .failed(String(localized: "The downloaded package isn't signed and notarized by Apple, so it wasn't opened."))
                return
            }

            phase = .installing
            NSWorkspace.shared.open(package)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(String(localized: "Download failed: \(error.localizedDescription)"))
        }
    }

    func reset() { phase = .idle }

    // MARK: - Helpers

    private func download(_ url: URL, to destination: URL) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                phase = .downloading(fraction: expected > 0 ? Double(received) / Double(expected) : nil)
            }
        }
        try handle.write(contentsOf: buffer)
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
