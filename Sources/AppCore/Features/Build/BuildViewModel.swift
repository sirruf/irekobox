import Foundation
import Observation
import ContainerKit

/// Drives the Build sheet: configure a build, stream `--progress plain` output,
/// parse stage/step, and optionally push the result.
@MainActor
@Observable
final class BuildViewModel {
    private let engine: any ContainerEngine

    enum Phase { case form, running, finished }

    // Form
    var dockerfilePath = ""
    var contextPath = ""
    var imageName = ""
    var tag = "latest"
    var alsoAMD64 = false
    var noCache = false

    // Run state
    var phase: Phase = .form
    var operation = String(localized: "Build", comment: "Title of a running image build")
    var logs: [LogLine] = []
    var currentStage = ""
    var step = 0
    var total = 0
    var succeeded = false
    var error: String?
    var builtTag: String?

    init(engine: any ContainerEngine) { self.engine = engine }

    var reference: String {
        let name = imageName.trimmingCharacters(in: .whitespaces)
        let t = tag.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? name : "\(name):\(t)"
    }

    var canBuild: Bool {
        !contextPath.isEmpty && !imageName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Determinate fraction, or nil for indeterminate.
    var fraction: Double? {
        total > 0 ? min(1, Double(step) / Double(total)) : nil
    }

    func startBuild() async {
        guard canBuild else { return }
        operation = String(localized: "Build", comment: "Title of a running image build")
        let options = BuildOptions(
            contextPath: contextPath,
            dockerfilePath: dockerfilePath.isEmpty ? nil : dockerfilePath,
            tag: reference,
            architectures: alsoAMD64 ? ["arm64", "amd64"] : [],
            noCache: noCache
        )
        await consume(engine.buildImage(options), successTag: reference)
    }

    func startPush(_ reference: String) async {
        operation = String(localized: "Push", comment: "Title of a running image push")
        await consume(engine.pushImage(reference), successTag: nil)
    }

    // MARK: - Stream consumption

    private func consume(_ stream: AsyncThrowingStream<String, Error>, successTag: String?) async {
        phase = .running
        logs = []; currentStage = ""; step = 0; total = 0
        succeeded = false; error = nil; builtTag = nil

        do {
            for try await line in stream {
                append(line)
            }
            if let errLine = logs.last(where: { $0.text.hasPrefix("Error") || $0.text.hasPrefix("error") }) {
                fail(with: errLine.text)
            } else {
                succeeded = true
                builtTag = successTag
            }
        } catch {
            fail(with: logs.last(where: { isErrorLine($0.text) })?.text ?? error.localizedDescription)
        }
        phase = .finished
    }

    private func fail(with message: String) {
        var text = message
        if logs.contains(where: { $0.text.lowercased().contains("unsupported") && $0.text.contains("platform") }) {
            text += "\n" + String(localized: "Tip: pre-pull the base image for that platform — `container image pull --platform linux/amd64 <base>` — then rebuild.")
        }
        error = text
        succeeded = false
    }

    private func isErrorLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("error") || lower.contains("unsupported")
    }

    /// Internal (not private) so progress parsing can be unit-tested.
    func append(_ line: String) {
        logs.append(LogLine(text: line))
        if logs.count > 4000 { logs.removeFirst(logs.count - 4000) }
        parse(line)
    }

    private static let stepRegex = try! NSRegularExpression(pattern: #"(\d+)/(\d+)\]"#)

    private func parse(_ line: String) {
        let range = NSRange(line.startIndex..., in: line)
        if let match = Self.stepRegex.firstMatch(in: line, range: range),
           let kRange = Range(match.range(at: 1), in: line),
           let nRange = Range(match.range(at: 2), in: line),
           let k = Int(line[kRange]), let n = Int(line[nRange]) {
            step = max(step, k)
            total = max(total, n)
        }
        if let bracket = line.range(of: "] ") {
            currentStage = String(line[bracket.upperBound...])
        } else if line.contains("exporting to") {
            currentStage = String(localized: "exporting image")
        } else if line.contains("pushing") || line.contains("pushed") {
            currentStage = String(localized: "pushing layers")
        }
    }
}

/// One line of build or push output.
struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
}
