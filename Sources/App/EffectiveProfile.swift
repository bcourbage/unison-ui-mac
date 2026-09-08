import Foundation

/// Where a profile line came from: upstream's `locname` plus the line number,
/// which is exactly how Unison's own error messages locate a line.
struct ProfileLocation: Equatable {
    /// `Profile "name" (file "path")` for a file read by name (the top-level
    /// profile and `include` targets), `File "path"` for a `source` target.
    let locName: String
    /// The file actually read.
    let path: String
    /// 1-based line number in that file.
    let line: Int
}

/// One `name = value` line, after Unison's own trimming, with its provenance.
struct ProfileAssignment: Equatable {
    /// The option name as written (may be an alias).
    let name: String
    /// The registered name the alias resolves to (equal to `name` otherwise).
    let canonicalName: String
    let value: String
    let location: ProfileLocation
}

/// A profile as Unison loads it: every included file spliced in place, every
/// line validated the way `Prefs.processLines` validates it, and every
/// assignment kept with its file and line so the effective value of a setting
/// can be attributed to the line that set it and the lines it overrode.
///
/// Mirrors `readAFile` / `parseLines` / `processLines` in
/// `src/ubase/prefs.ml` (upstream v2.54.0, commit 91421d0). The rules:
///
/// - Files are read line by line (`input_line`: LF-separated; a final line
///   without LF is still a line). A UTF-8 byte-order mark at the start of the
///   file is skipped and one trailing CR per line is removed.
/// - A line whose trimmed form (spaces, tabs, CR, LF) is empty or starts with
///   `#` is skipped.
/// - Directive detection uses the untrimmed line: `include `, `source `,
///   `include? `, `source? ` at column zero. The line is split into words
///   with `PrefsTokenizer`; anything but exactly two words is
///   "Garbled 'include' directive". `include` appends `.prf` unless a file
///   with the exact name exists; `source` uses the name literally; the `?`
///   forms skip a missing file. Included lines are spliced in place.
/// - Every other line must contain `=`: the text before the first `=` is the
///   name and the text after it the value, both trimmed. No `=` is
///   "Garbled line (no '=')".
/// - Parsing walks each file from its last line to its first (upstream
///   accumulates lines in reverse and parses the reversed list), so of two
///   parse-time errors in one file the later line is reported. Includes are
///   read during this walk, so an included file's errors surface at the point
///   of its directive. Value processing then walks the spliced list from first
///   to last, so every parse-time error precedes every processing error.
/// - Processing rejects an unregistered or pseudo name ("`x' is not a valid
///   option"), a command-line-only name ("is a command line-only option"),
///   a boolean value other than `true`/`false`, and an integer value
///   `int_of_string` rejects; each stops the load with Unison's message.
///
/// Value checks cover boolean and integer preferences only, with upstream's
/// rules (`true`/`false`; `int_of_string` including its range). Values of
/// string, list and custom preferences are recorded as written and are not
/// validated here, so a value Unison's own parser would reject (a malformed
/// pattern, an unknown `ui` name) is not detected at this stage.
///
/// Three conditions Unison does not detect are reported as this check's own
/// errors, in its own words: an inclusion cycle (upstream would recurse until
/// it ran out of stack), an include graph larger than the design's bounds
/// (depth 16, 64 file reads counting repeats, so an acyclic graph that
/// re-includes files exponentially cannot run away), and a file that exists
/// but cannot be read as text (upstream reads bytes and might load it).
struct EffectiveProfile: Equatable {

    enum LoadError: Error, Equatable {
        /// Unison would refuse to load the profile; the text is Unison's.
        case fatal(String)
        /// The check itself could not establish what Unison would read.
        case notEstablished(String)

        var message: String {
            switch self {
            case .fatal(let s), .notEstablished(let s): return s
            }
        }
    }

    /// The winning assignment of a scalar setting and the ones it overrode.
    struct Scalar: Equatable {
        let value: String
        let winner: ProfileAssignment
        /// Earlier assignments of the same setting, in spliced order.
        let overridden: [ProfileAssignment]
    }

    /// The profile name given to the loader (without `.prf`).
    let profile: String
    /// Files read, in the order Unison opens them (top-level first). A file
    /// included twice appears twice, as upstream reads it twice.
    let files: [String]

    /// A path whose existence decided how resolution proceeded: every lookup
    /// candidate `profilePathname` probed (the exact name and the `.prf`
    /// form), every optional target found absent, and every file read. A
    /// path that later appears or disappears changes the effective profile
    /// even when no file that was read has changed.
    struct ResolutionDependency: Equatable, Hashable {
        let path: String
        let present: Bool
    }
    /// Deduplicated, in first-encounter order.
    let dependencies: [ResolutionDependency]
    /// Every validated assignment in spliced order.
    let assignments: [ProfileAssignment]

    /// Effective value of a scalar setting: the last assignment in spliced
    /// order wins. Nil when the profile never sets it. The name may be an
    /// alias; assignments are matched by canonical name.
    func scalar(_ name: String) -> Scalar? {
        let canonical = UnisonPreferenceCatalog.entry(for: name)?.name ?? name
        let all = assignments.filter { $0.canonicalName == canonical }
        guard let winner = all.last else { return nil }
        return Scalar(value: winner.value, winner: winner, overridden: Array(all.dropLast()))
    }

    /// Every assignment of a list setting, in spliced order.
    func list(_ name: String) -> [ProfileAssignment] {
        let canonical = UnisonPreferenceCatalog.entry(for: name)?.name ?? name
        return assignments.filter { $0.canonicalName == canonical }
    }

    /// The `root` values in order.
    var roots: [String] { list("root").map(\.value) }

    /// A validated boolean setting (`true`/`false` was enforced at load).
    func bool(_ name: String) -> Bool? {
        guard let s = scalar(name) else { return nil }
        return s.value == "true"
    }

    // MARK: - Loading

    /// Design bounds: nesting depth and total file reads (repeats included).
    static let maxInclusionDepth = 16
    static let maxFileReads = 64

    /// Load `profile` from `unisonDirectory` as Unison would. `read` is the
    /// same injectable reader `ProfileRootResolver` uses.
    static func load(profile: String,
                     unisonDirectory: String,
                     read: @escaping (String) -> ProfileRootResolver.ReadResult = ProfileRootResolver.filesystemRead)
        -> Result<EffectiveProfile, LoadError>
    {
        var loader = Loader(unisonDirectory: unisonDirectory, read: read)
        do {
            let parsed = try loader.readAFile(profile, fail: true, addExt: true)
            let assignments = try process(parsed)
            return .success(EffectiveProfile(profile: profile,
                                             files: loader.filesRead,
                                             dependencies: loader.dependencies,
                                             assignments: assignments))
        } catch let e as LoadError {
            return .failure(e)
        } catch {
            return .failure(.notEstablished(String(describing: error)))
        }
    }

    /// `(loc, varName, theResult)` as produced by `parseLines`.
    struct ParsedLine: Equatable {
        let location: ProfileLocation
        let name: String
        let value: String
    }

    private struct Loader {
        let unisonDirectory: String
        let read: (String) -> ProfileRootResolver.ReadResult
        var filesRead: [String] = []
        var dependencies: [ResolutionDependency] = []

        private mutating func note(_ path: String, present: Bool) {
            let d = ResolutionDependency(path: path, present: present)
            if !dependencies.contains(d) { dependencies.append(d) }
        }
        /// Canonical paths of the files currently being read (cycle check).
        var openStack: [String] = []

        init(unisonDirectory: String, read: @escaping (String) -> ProfileRootResolver.ReadResult) {
            self.unisonDirectory = unisonDirectory
            self.read = read
        }

        private func exists(_ path: String) -> Bool {
            // `System.file_exists`: any existing path counts, a directory too.
            read(path) != .missing
        }

        /// `Prefs.profilePathname`.
        private mutating func profilePathname(_ n: String, addExt: Bool) -> String {
            let f = ProfileRootResolver.fileInUnisonDir(unisonDirectory, n)
            if !addExt { return f }
            let exact = exists(f)
            note(f, present: exact)
            if exact { return f }
            return ProfileRootResolver.fileInUnisonDir(unisonDirectory, n + ".prf")
        }

        /// `readAFile ~fail ~add_ext filename`, returning parsed lines in
        /// file order with included files spliced in.
        mutating func readAFile(_ filename: String, fail: Bool, addExt: Bool) throws -> [ParsedLine] {
            let path = profilePathname(filename, addExt: addExt)
            let locName = addExt
                ? "Profile \"\(filename)\" (file \"\(path)\")"
                : "File \"\(path)\""
            let text: String
            switch read(path) {
            case .missing:
                note(path, present: false)
                if !fail { return [] }
                if addExt {
                    throw LoadError.fatal("Profile \(filename) not found (looking for file \(path))")
                }
                throw LoadError.fatal("Preference file \(path) not found")
            case .unreadable:
                throw LoadError.notEstablished(
                    "\(locName) exists but could not be read as text. "
                    + "Unison reads profiles as bytes and may load it; the check cannot.")
            case .ok(let t):
                text = t
            }
            let canonical = (path as NSString).standardizingPath
            if openStack.contains(canonical) {
                throw LoadError.notEstablished(
                    "\(locName) is already being read: the profile includes itself.")
            }
            if openStack.count >= EffectiveProfile.maxInclusionDepth {
                throw LoadError.notEstablished(
                    "\(locName): inclusion depth exceeds \(EffectiveProfile.maxInclusionDepth).")
            }
            if filesRead.count >= EffectiveProfile.maxFileReads {
                throw LoadError.notEstablished(
                    "\(locName): the profile reads more than \(EffectiveProfile.maxFileReads) files through its includes.")
            }
            note(path, present: true)
            filesRead.append(path)
            openStack.append(canonical)
            defer { openStack.removeLast() }
            return try parseLines(EffectiveProfile.rawLines(of: text), locName: locName, path: path)
        }

        /// `parseLines`: walks the file's lines from last to first (as
        /// upstream does with its reversed accumulator) and returns them in
        /// forward order with includes spliced at their directive.
        private mutating func parseLines(_ lines: [String], locName: String, path: String) throws -> [ParsedLine] {
            var result: [ParsedLine] = []          // built back to front
            for (index, rawLine) in lines.enumerated().reversed() {
                let lineNum = index + 1
                let loc = ProfileLocation(locName: locName, path: path, line: lineNum)
                let theLine = EffectiveProfile.removeTrailingCR(rawLine)
                let l = EffectiveProfile.trimWhitespace(theLine)
                if l.isEmpty || l.hasPrefix("#") { continue }

                func includes(fail: Bool, addExt: Bool) throws {
                    let words = PrefsTokenizer.splitIntoWords(theLine)
                    guard words.count == 2 else {
                        throw LoadError.fatal("\(locName), line \(lineNum):\nGarbled 'include' directive: \(theLine)")
                    }
                    let sublines: [ParsedLine]
                    do {
                        sublines = try readAFile(words[1], fail: fail, addExt: addExt)
                    } catch LoadError.fatal(let err) {
                        throw LoadError.fatal(
                            "Included from \(EffectiveProfile.uncapitalizeASCII(locName)), line \(lineNum):\n\(err)")
                    }
                    result.insert(contentsOf: sublines, at: 0)
                }

                if theLine.hasPrefix("include ") {
                    try includes(fail: true, addExt: true)
                } else if theLine.hasPrefix("source ") {
                    try includes(fail: true, addExt: false)
                } else if theLine.hasPrefix("include? ") {
                    try includes(fail: false, addExt: true)
                } else if theLine.hasPrefix("source? ") {
                    try includes(fail: false, addExt: false)
                } else if let eq = theLine.unicodeScalars.firstIndex(of: "=") {
                    let name = EffectiveProfile.trimWhitespace(String(theLine.unicodeScalars[..<eq]))
                    let value = EffectiveProfile.trimWhitespace(
                        String(theLine.unicodeScalars[theLine.unicodeScalars.index(after: eq)...]))
                    result.insert(ParsedLine(location: loc, name: name, value: value), at: 0)
                } else {
                    throw LoadError.fatal("\(locName), line \(lineNum):\nGarbled line (no '='): \(theLine)")
                }
            }
            return result
        }
    }

    /// `processLines`: validate every parsed line against the engine's
    /// preference table, in spliced order, stopping at the first error.
    static func process(_ lines: [ParsedLine]) throws -> [ProfileAssignment] {
        var out: [ProfileAssignment] = []
        for line in lines {
            let where_ = "\(line.location.locName), line \(line.location.line)"
            guard let entry = UnisonPreferenceCatalog.entry(for: line.name), !entry.pseudo else {
                throw LoadError.fatal("\(where_): `\(line.name)' is not a valid option")
            }
            if entry.commandLineOnly {
                throw LoadError.fatal(
                    "\(where_): \"\(line.name)\" is a command line-only option; it must not be present in a profile.")
            }
            switch entry.kind {
            case .bool:
                guard line.value == "true" || line.value == "false" else {
                    throw LoadError.fatal("\(line.name) expects a boolean value, but \n\(line.value) is not a boolean")
                }
            case .int:
                guard isOCamlInt(line.value) else {
                    throw LoadError.fatal("\(line.name) expects an integer value, but\n\(line.value) is not an integer")
                }
            case .string, .list, .custom:
                break
            }
            out.append(ProfileAssignment(name: line.name, canonicalName: entry.name,
                                         value: line.value, location: line.location))
        }
        return out
    }

    // MARK: - Upstream string helpers

    /// Lines as OCaml `input_line` yields them: split at LF; a trailing LF
    /// does not start an empty final line. The UTF-8 BOM, if the reader left
    /// one, is dropped from the first line.
    static func rawLines(of text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        if let first = lines.first, first.unicodeScalars.first == "\u{FEFF}" {
            lines[0] = String(first.unicodeScalars.dropFirst())
        }
        return lines
    }

    /// `Util.removeTrailingCR`: exactly one trailing CR.
    static func removeTrailingCR(_ s: String) -> String {
        guard s.unicodeScalars.last == "\r" else { return s }
        return String(s.unicodeScalars.dropLast())
    }

    /// `Util.trimWhitespace`: strips spaces, tabs, LF and CR at both ends.
    static func trimWhitespace(_ s: String) -> String {
        let ws: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]
        var scalars = s.unicodeScalars[...]
        while let f = scalars.first, ws.contains(f) { scalars.removeFirst() }
        while let l = scalars.last, ws.contains(l) { scalars.removeLast() }
        return String(scalars)
    }

    /// `String.uncapitalize_ascii`: lowercases the first character when it is
    /// an ASCII letter.
    static func uncapitalizeASCII(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, first.isASCII, first.properties.isUppercase else { return s }
        return String(first).lowercased() + String(s.unicodeScalars.dropFirst())
    }

    /// Whether OCaml's `int_of_string` accepts the text, following
    /// `parse_intnat` in the OCaml runtime (`runtime/ints.c`) for a 63-bit
    /// `int`: an optional sign, an optional `0x`/`0o`/`0b`/`0u` prefix, at
    /// least one digit of the base, underscores allowed after the first digit,
    /// and the range check: decimal literals are signed (`-2^62 … 2^62-1`);
    /// prefixed literals are unsigned and accept magnitudes below `2^63`
    /// with either sign (they wrap, as upstream's do).
    static func isOCamlInt(_ s: String) -> Bool {
        var scalars = s.unicodeScalars[...]
        var negative = false
        if let f = scalars.first, f == "-" || f == "+" {
            negative = f == "-"
            scalars.removeFirst()
        }
        var base: UInt64 = 10
        var signed = true
        if scalars.count >= 2, scalars.first == "0" {
            switch scalars[scalars.index(after: scalars.startIndex)] {
            case "x", "X": base = 16; signed = false; scalars.removeFirst(2)
            case "o", "O": base = 8; signed = false; scalars.removeFirst(2)
            case "b", "B": base = 2; signed = false; scalars.removeFirst(2)
            case "u", "U": base = 10; signed = false; scalars.removeFirst(2)
            default: break
            }
        }
        func digit(_ c: Unicode.Scalar) -> UInt64? {
            let v: UInt64
            switch c {
            case "0"..."9": v = UInt64(c.value - 48)
            case "a"..."z": v = UInt64(c.value - 97 + 10)
            case "A"..."Z": v = UInt64(c.value - 65 + 10)
            default: return nil
            }
            return v < base ? v : nil
        }
        guard let first = scalars.first, let d0 = digit(first) else { return false }
        var result = d0
        for c in scalars.dropFirst() {
            if c == "_" { continue }
            guard let d = digit(c) else { return false }
            let (m, o1) = result.multipliedReportingOverflow(by: base)
            let (a, o2) = m.addingReportingOverflow(d)
            if o1 || o2 { return false }
            result = a
        }
        let limit: UInt64 = signed ? (1 << 62) : (1 << 63)
        if signed {
            return negative ? result <= limit : result < limit
        }
        return result < limit
    }
}
