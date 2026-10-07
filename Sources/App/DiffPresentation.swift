import Foundation

/// What the Diff window shows for one engine result. Unison hands the window
/// the command line it ran (as the title) and the command's output with the
/// process status appended (as the text). The window title names the file,
/// the two compared files are secondary information, the command line is
/// available on request, and a `diff` exit status is read for the user.
struct DiffPresentation: Equatable {
    /// Window title: "Diff — <file name>".
    let title: String
    /// The row's path within the replicas.
    let path: String
    /// The two files the command compared, when they can be read from the
    /// command line (the engine quotes them); otherwise empty.
    let endpoints: [String]
    /// The command line exactly as the engine ran it.
    let command: String
    /// The command's output without the appended status line.
    let body: String
    /// The status, in words for the standard `diff` command.
    let status: String?

    static func make(path: String, command: String, output: String) -> DiffPresentation {
        let name = (path as NSString).lastPathComponent
        let (body, statusLine) = splitStatus(output)
        return DiffPresentation(
            title: "Diff — \(name.isEmpty ? path : name)",
            path: path,
            endpoints: fileOperands(in: command),
            command: command,
            body: body,
            status: statusLine.map { interpret(statusLine: $0, command: command) })
    }

    /// One shell word of the command line, with how it was written.
    struct Token: Equatable {
        let text: String
        let quoted: Bool
        /// An unquoted shell control operator (`|`, `;`, `&&`, `||`, `&`,
        /// `>`, `<`, `` ` ``, `$(`): the command is more than one program.
        let isOperator: Bool
    }

    /// Split a command line into shell words, honouring single quotes (with
    /// the `'\''` escape the engine uses), double quotes and backslashes, and
    /// marking control operators. Enough of the shell grammar to tell a
    /// standalone program from a pipeline and a quoted file from an option.
    static func tokenize(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quotedWord = false
        var i = command.startIndex
        func flush() {
            if !current.isEmpty || quotedWord {
                tokens.append(Token(text: current, quoted: quotedWord, isOperator: false))
            }
            current = ""; quotedWord = false
        }
        while i < command.endIndex {
            let c = command[i]
            switch c {
            case "'":
                quotedWord = true
                i = command.index(after: i)
                while i < command.endIndex {
                    if command[i...].hasPrefix("'\\''") {
                        current.append("'"); i = command.index(i, offsetBy: 4); continue
                    }
                    if command[i] == "'" { break }
                    current.append(command[i]); i = command.index(after: i)
                }
                if i < command.endIndex { i = command.index(after: i) }
                continue
            case "\"":
                quotedWord = true
                i = command.index(after: i)
                while i < command.endIndex, command[i] != "\"" {
                    if command[i] == "\\", command.index(after: i) < command.endIndex {
                        i = command.index(after: i)
                    }
                    current.append(command[i]); i = command.index(after: i)
                }
                if i < command.endIndex { i = command.index(after: i) }
                continue
            case "\\":
                let next = command.index(after: i)
                if next < command.endIndex {
                    // Backslash-newline is a line continuation: no character.
                    if command[next] != "\n" { current.append(command[next]) }
                    i = command.index(after: next)
                } else {
                    i = next
                }
                continue
            case " ", "\t":
                flush()
            case "\n", "\r", "\r\n":   // CRLF is one Character in Swift
                // An unquoted newline separates commands, like `;`. A quoted
                // newline is text (handled in the quote branches above) and a
                // backslash-newline continuation is consumed by the `\` case.
                flush()
                tokens.append(Token(text: "\n", quoted: false, isOperator: true))
            case "|", ";", "&", ">", "<", "`":
                flush()
                var op = String(c)
                let next = command.index(after: i)
                if next < command.endIndex, (c == "|" || c == "&" || c == ">") , command[next] == c {
                    op.append(c); i = next
                }
                tokens.append(Token(text: op, quoted: false, isOperator: true))
            case "$":
                let next = command.index(after: i)
                if next < command.endIndex, command[next] == "(" {
                    flush()
                    tokens.append(Token(text: "$(", quoted: false, isOperator: true))
                    i = next
                } else {
                    current.append(c)
                }
            default:
                current.append(c)
            }
            i = command.index(after: i)
        }
        flush()
        return tokens
    }

    /// The two files the engine substituted into the command: the quoted
    /// absolute paths. Exactly two must be present, or nothing is claimed,
    /// since a quoted option value (`-L 'Original'`) is not a file.
    static func fileOperands(in command: String) -> [String] {
        let paths = tokenize(command)
            .filter { $0.quoted && !$0.isOperator && $0.text.hasPrefix("/") }
            .map(\.text)
        return paths.count == 2 ? paths : []
    }

    /// The engine appends "\n\n" + one of `Exited with status N`, `Killed by
    /// signal N`, `Stopped by signal N` to the command's output.
    static func splitStatus(_ output: String) -> (body: String, statusLine: String?) {
        let trimmed = output.hasSuffix("\n") ? String(output.dropLast()) : output
        guard let range = trimmed.range(of: "\n\n", options: .backwards) else {
            return (output, nil)
        }
        let last = String(trimmed[range.upperBound...])
        let isStatus = ["Exited with status ", "Killed by signal ", "Stopped by signal "]
            .contains { last.hasPrefix($0) }
        guard isStatus else { return (output, nil) }
        return (String(trimmed[..<range.lowerBound]), last)
    }

    /// `diff(1)` defines its exit status: 0 no differences, 1 differences,
    /// 2 trouble. Another command's status is shown as the engine reported it.
    static func interpret(statusLine: String, command: String) -> String {
        guard isStandardDiff(command),
              statusLine.hasPrefix("Exited with status "),
              let code = Int(statusLine.dropFirst("Exited with status ".count)) else {
            return statusLine
        }
        switch code {
        case 0: return "No differences."
        case 1: return "Differences found."
        default: return "diff reported a problem (exit status \(code))."
        }
    }

    /// True when the command line is a single `diff` invocation (any path to
    /// the program) with no shell operator, so the exit status is diff's
    /// own. A pipeline such as `diff -u OLDER NEWER | cat` reports the
    /// pipeline's status, which says nothing about differences.
    static func isStandardDiff(_ command: String) -> Bool {
        let tokens = tokenize(command)
        guard let first = tokens.first, !first.isOperator,
              !tokens.contains(where: \.isOperator) else { return false }
        return (first.text as NSString).lastPathComponent == "diff"
    }
}
