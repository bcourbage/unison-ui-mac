import Foundation

/// The word splitter Unison applies to profile text: `Util.splitIntoWords`
/// in `src/ubase/util.ml` (upstream v2.54.0). Unison uses it to split the
/// `include`/`source` directive line, and `remote.ml` uses it to split every
/// piece of the ssh command line (`sshargs`, `servercmd -server …`) into
/// separate `execv` arguments.
///
/// Rules, one per branch of the OCaml function:
/// - The separator is exactly one character, a space by default. Tabs and
///   other whitespace are ordinary word characters.
/// - A run of separators ends a word; separators between words produce no
///   empty words, and leading or trailing separators produce none either.
/// - The escape character (backslash) is consumed and the character after it
///   is taken literally, whatever it is, including a separator or another
///   escape.
/// - An escape that is the last character of the string is dropped.
///
/// The app has exactly one implementation of these rules; every caller that
/// must agree with Unison about word boundaries uses this type.
enum PrefsTokenizer {

    static let separator: Unicode.Scalar = " "
    static let escape: Unicode.Scalar = "\\"

    /// `Util.splitIntoWords s c` with `esc = '\\'`.
    ///
    /// Works on Unicode scalars. Upstream works on bytes, and the escape
    /// consumes one byte; for a multi-byte UTF-8 character after a backslash
    /// the remaining continuation bytes are then read as ordinary word
    /// content, so the byte sequence of the resulting word is identical to
    /// consuming the whole scalar here.
    static func splitIntoWords(_ s: String,
                               separator c: Unicode.Scalar = PrefsTokenizer.separator) -> [String] {
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        var words: [String] = []
        var i = 0
        while i < n {
            // betweenwords: skip separators.
            if scalars[i] == c { i += 1; continue }
            // inword: collect until the next separator or end of string.
            var word = String.UnicodeScalarView()
            while i < n && scalars[i] != c {
                if scalars[i] == escape {
                    if i + 1 >= n {
                        i += 1                       // ignore final esc
                    } else {
                        word.append(scalars[i + 1])  // take any following char
                        i += 2
                    }
                } else {
                    word.append(scalars[i])
                    i += 1
                }
            }
            words.append(String(word))
        }
        return words
    }

    /// The string a remote login shell receives for a list of words that ssh
    /// was given as separate arguments after the destination: OpenSSH joins
    /// them with single spaces and passes the result to the remote shell for
    /// re-parsing.
    static func joinedForRemoteShell(_ words: [String]) -> String {
        words.joined(separator: " ")
    }
}
