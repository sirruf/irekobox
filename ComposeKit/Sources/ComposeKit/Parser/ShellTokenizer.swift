import Foundation

/// Splits a shell-form string (compose `command`/`entrypoint` string syntax)
/// into argv, honoring quotes and backslash escapes — so
/// `redis-server --appendonly yes` → `["redis-server", "--appendonly", "yes"]`.
public enum ShellTokenizer {
    public static func split(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch); escaped = false; hasToken = true; continue
            }
            if ch == "\\" && !inSingle { escaped = true; hasToken = true; continue }
            if ch == "'" && !inDouble { inSingle.toggle(); hasToken = true; continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); hasToken = true; continue }
            if (ch == " " || ch == "\t" || ch == "\n") && !inSingle && !inDouble {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch); hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}

public extension StringOrList {
    /// For `command` / `entrypoint`: a list is used as-is (exec form); a string
    /// is shell-tokenized (shell form). Differs from ``values`` (which keeps a
    /// string whole — correct for `dns` / `env_file`).
    var shellWords: [String] {
        switch self {
        case .list(let list): return list
        case .string(let string): return ShellTokenizer.split(string)
        }
    }
}
