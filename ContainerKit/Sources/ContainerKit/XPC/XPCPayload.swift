import Foundation

/// Converts apiserver XPC payloads into the JSON shape the `container` CLI
/// prints, so the same models decode both.
///
/// The apiserver encodes with `JSONEncoder` defaults: dates are seconds since
/// 2001-01-01; the CLI prints ISO-8601. A container snapshot also differs in
/// layout:
///
///     XPC: { configuration, status: "running", networks: [...], startedDate }
///     CLI: { id, configuration, status: { state, networks, startedDate } }
enum XPCPayload {
    /// Keys whose numeric values are `Date`s in the XPC encoding.
    static let dateKeys: Set<String> = ["creationDate", "startedDate", "modificationDate"]

    /// `[ContainerSnapshot]` → CLI `list --format json` shape.
    static func containers(_ data: Data) throws -> Data {
        guard let snapshots = try parse(data) as? [[String: Any]] else {
            throw EngineError.decoding("container list is not an array")
        }
        return try serialize(snapshots.map(container))
    }

    /// `[VolumeConfiguration]` → CLI `volume ls --format json` shape.
    static func volumes(_ data: Data) throws -> Data {
        guard let configurations = try parse(data) as? [[String: Any]] else {
            throw EngineError.decoding("volume list is not an array")
        }
        return try serialize(configurations.map { ["id": $0["name"] ?? "", "configuration": $0] })
    }

    /// Payloads that already match the CLI shape apart from date encoding
    /// (networks, stats, disk usage).
    static func normalizingDates(_ data: Data) throws -> Data {
        try serialize(parse(data))
    }

    // MARK: - Private

    private static func container(_ snapshot: [String: Any]) -> [String: Any] {
        let configuration = snapshot["configuration"] as? [String: Any] ?? [:]
        var status: [String: Any] = [
            "state": snapshot["status"] as? String ?? "unknown",
            "networks": snapshot["networks"] ?? [],
        ]
        if let started = snapshot["startedDate"] { status["startedDate"] = started }
        return ["id": configuration["id"] ?? "", "configuration": configuration, "status": status]
    }

    private static func parse(_ data: Data) throws -> Any {
        do {
            return convertDates(try JSONSerialization.jsonObject(with: data))
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.decoding("invalid apiserver JSON: \(error.localizedDescription)")
        }
    }

    private static func serialize(_ object: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw EngineError.decoding("could not re-encode apiserver JSON")
        }
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Recursively replace reference-date numbers under ``dateKeys`` with ISO-8601.
    private static func convertDates(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                if dateKeys.contains(key), let seconds = (child as? NSNumber)?.doubleValue {
                    result[key] = isoFormatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
                } else {
                    result[key] = convertDates(child)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(convertDates)
        }
        return value
    }
}
