import Foundation

/// Status of the BuildKit builder from `container builder status --format json`.
///
/// Returns the builder container (same shape as `inspect`) whether it is running
/// or stopped; an empty array means no builder exists. The running state comes
/// from `status.state`. Parsed leniently rather than modeling the full object.
public struct BuilderStatus: Sendable, Hashable, Codable {
    public let isRunning: Bool
    public let detail: String?

    public init(isRunning: Bool, detail: String?) {
        self.isRunning = isRunning
        self.detail = detail
    }

    public static func parse(_ data: Data) -> BuilderStatus {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              !array.isEmpty else {
            return BuilderStatus(isRunning: false, detail: nil)
        }
        let builder = array.first as? [String: Any]
        let id = builder?["id"] as? String
        let state = (builder?["status"] as? [String: Any])?["state"] as? String
        return BuilderStatus(isRunning: state?.lowercased() == "running", detail: id)
    }
}
