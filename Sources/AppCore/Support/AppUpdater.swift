import Foundation
import AppKit
import CryptoKit
import Observation
import Security

/// Updates Irekobox itself from its own appcast (no Sparkle): a
/// small JSON file next to the release zip. The download must match the
/// appcast's SHA-256 and be signed with our Developer ID and notarized;
/// then the running bundle is replaced (the old one goes to the Trash) and
/// the app relaunches.
@MainActor
@Observable
public final class AppUpdater {
    struct Appcast: Codable, Equatable, Sendable {
        let version: String
        let build: Int
        let url: URL
        let sha256: String
        let notes: String?
        let minimumSystemVersion: String?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(Appcast)
        case downloading
        case installing
        case failed(String)
    }

    /// The appcast URL: Info.plist `IrekoboxAppcastURL` (set by scripts/release.sh)
    /// or the `appcastURL` default; nil means updates aren't offered.
    static var appcastURL: URL? {
        let text = UserDefaults.standard.string(forKey: "appcastURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "IrekoboxAppcastURL") as? String
        return text.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// Developer ID Application certificate of our team, for this app, notarized.
    nonisolated static let requirement = #"identifier "com.irekobox.app" and anchor apple generic and certificate leaf[subject.OU] = "YBKR9G3374" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"#

    nonisolated static let interval: TimeInterval = 24 * 3600

    private(set) var phase: Phase = .idle
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "checkAppUpdates") }
    }
    /// A check found a newer version (once per check).
    @ObservationIgnored var onAvailable: ((Appcast) -> Void)?
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// The version a check found, until it is installed: a check runs once a
    /// day, so without this a relaunch would forget an update until the next.
    private static let foundKey = "appAvailableUpdate"

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "checkAppUpdates") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.foundKey),
           let found = try? JSONDecoder().decode(Appcast.self, from: data),
           Self.isNewer(found, than: Self.installedBuild) {
            phase = .available(found)
        }
    }

    /// Check now if due, then again whenever a day has passed while the app
    /// keeps running.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Newer than what runs, and runs on this macOS.
    nonisolated static func isNewer(_ appcast: Appcast, than build: Int) -> Bool {
        guard appcast.build > build else { return false }
        guard let minimum = appcast.minimumSystemVersion else { return true }
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts[2]))
    }

    public func checkIfDue(force: Bool = false) async {
        guard isEnabled || force, let url = Self.appcastURL else { return }
        let last = UserDefaults.standard.double(forKey: "appLastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > Self.interval else { return }
        phase = .checking
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let appcast = try JSONDecoder().decode(Appcast.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "appLastUpdateCheck")
            if Self.isNewer(appcast, than: Self.installedBuild) {
                phase = .available(appcast)
                UserDefaults.standard.set(try? JSONEncoder().encode(appcast), forKey: Self.foundKey)
                onAvailable?(appcast)
            } else {
                phase = .idle
                UserDefaults.standard.removeObject(forKey: Self.foundKey)
            }
        } catch {
            if force {
                phase = .failed(String(localized: "Couldn't check for updates: \(error.localizedDescription)"))
            } else if phase == .checking {
                phase = Self.found.map { .available($0) } ?? .idle
            }
        }
    }

    private static var found: Appcast? {
        UserDefaults.standard.data(forKey: foundKey).flatMap { try? JSONDecoder().decode(Appcast.self, from: $0) }
            .flatMap { isNewer($0, than: installedBuild) ? $0 : nil }
    }

    /// Download, verify, replace and relaunch.
    func install(_ appcast: Appcast) async {
        phase = .downloading
        do {
            let folder = FileManager.default.temporaryDirectory.appending(path: "irekobox-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (downloaded, _) = try await URLSession.shared.download(from: appcast.url)
            let zip = folder.appending(path: "update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            phase = .installing
            let app = try await Task.detached { try Self.prepare(zip: zip, sha256: appcast.sha256, in: folder) }.value
            try Self.replace(Bundle.main.bundleURL, with: app)
            Self.relaunch(Bundle.main.bundleURL)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    struct UpdateError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Check the hash, unpack, find the app and check its signature.
    nonisolated static func prepare(zip: URL, sha256: String, in folder: URL) throws -> URL {
        let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw UpdateError(message: String(localized: "The download doesn't match the published checksum.")) }
        let unpacked = folder.appending(path: "unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError(message: String(localized: "Couldn't unpack the update.")) }
        guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError(message: String(localized: "The update has no app in it.")) }
        if let problem = signatureProblem(app, requirement: requirement) {
            throw UpdateError(message: String(localized: "The update isn't signed by Irekobox's developer: \(problem)"))
        }
        return app
    }

    /// nil when `app` (and all code inside) is validly signed and meets `requirement`.
    nonisolated static func signatureProblem(_ app: URL, requirement text: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return "not code" }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return "bad requirement" }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
        }
        return nil
    }

    /// Move the old bundle to the Trash and the new one into its place; put
    /// the old one back if the move fails.
    nonisolated static func replace(_ current: URL, with new: URL) throws {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: new, to: current)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: current) }
            throw UpdateError(message: String(localized: "Couldn't put the new version in place: \(error.localizedDescription)"))
        }
    }

    /// Open the new bundle once this process has quit.
    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
