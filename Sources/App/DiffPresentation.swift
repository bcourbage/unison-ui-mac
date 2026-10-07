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
            endpoints: quotedArguments(in: command),
            command: command,
            body: body,
            status: statusLine.map { interpret(statusLine: $0, command: command) })
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

    /// True when the command's program is `diff` (any path), so its exit
    /// status has the documented meaning.
    static func isStandardDiff(_ command: String) -> Bool {
        let first = command.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let program = first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return (program as NSString).lastPathComponent == "diff"
    }

    /// The single-quoted arguments of a shell command line, unescaped. The
    /// engine quotes each file path as `'…'` with an embedded quote written
    /// as `'\''`.
    static func quotedArguments(in command: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuote = false
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            if inQuote {
                if c == "'" {
                    // `'\''` closes, escapes a quote, reopens.
                    let rest = command[i...]
                    if rest.hasPrefix("'\\''") {
                        current.append("'")
                        i = command.index(i, offsetBy: 4)
                        continue
                    }
                    inQuote = false
                    out.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            } else if c == "'" {
                inQuote = true
            }
            i = command.index(after: i)
        }
        return out
    }
}
