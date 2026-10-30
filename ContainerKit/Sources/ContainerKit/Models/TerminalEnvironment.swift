import Foundation

/// What an interactive shell inside a container needs from us. Images set
/// no locale, so the shell runs in POSIX and treats each byte of non-ASCII
/// input (Cyrillic, accents) as a character of its own; C.UTF-8 exists in
/// every image. TERM matches what the app's terminal emulates.
public enum TerminalEnvironment {
    public static let variables = ["LANG=C.UTF-8", "TERM=xterm-256color"]

    /// `--env` flags for `container exec` / `container machine run`.
    public static var flags: [String] { variables.flatMap { ["--env", $0] } }
}
