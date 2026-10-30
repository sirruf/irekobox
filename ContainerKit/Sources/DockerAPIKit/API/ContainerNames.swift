import Foundation

/// Docker-style names for containers created without one.
enum ContainerNames {
    static let adjectives = ["admiring", "bold", "brave", "calm", "clever", "eager", "elegant", "festive",
                             "focused", "gallant", "happy", "jolly", "keen", "lucid", "modest", "nifty",
                             "quirky", "serene", "sharp", "stoic", "tender", "vibrant", "wizardly", "zealous"]
    static let surnames = ["allen", "babbage", "curie", "darwin", "einstein", "feynman", "goldberg", "hopper",
                           "hypatia", "johnson", "kepler", "lamarr", "lovelace", "meitner", "newton", "noether",
                           "pascal", "ritchie", "shannon", "thompson", "turing", "wiles", "wozniak", "yalow"]

    static func random() -> String {
        "\(adjectives.randomElement()!)_\(surnames.randomElement()!)"
    }

    /// Docker's rule: `[a-zA-Z0-9][a-zA-Z0-9_.-]+`.
    static func isValid(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.-]+/) != nil
    }
}

/// A free TCP port on the host for bindings that leave the host port empty.
enum FreePort {
    static func pick() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerAPIError(500, "no free port: socket failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw DockerAPIError(500, "no free port: bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
