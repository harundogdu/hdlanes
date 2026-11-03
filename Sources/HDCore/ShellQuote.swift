import Foundation

/// POSIX shell quoting. Every value interpolated into a command line goes through `quote`.
public enum ShellQuote {
    /// Wraps `value` in single quotes; an embedded `'` becomes `'\''`. Safe for any byte sequence
    /// in sh/bash/zsh/ksh/dash, including `$`, backticks, `!` and newlines.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Quotes each word and joins them with spaces.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
