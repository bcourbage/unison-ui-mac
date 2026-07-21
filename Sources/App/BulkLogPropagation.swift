import Foundation

/// Honest bulk propagation of the shared-logging setting to every profile that
/// has logging on ("Settings → shared logging → Update All").
///
/// The previous implementation returned only an `Int` of updated profiles and
/// silently swallowed read failures, write failures, and a directory-enumeration
/// failure — so a partial or total failure was reported as "No profiles needed
/// updating". This engine instead produces a structured `Result` and a pure
/// `Outcome` so the UI can distinguish nothing-needed / complete-success /
/// partial-success / complete-failure / cannot-enumerate.
///
/// All filesystem effects are behind closures so the whole thing is
/// deterministically testable with fault injection. Writes go through the
/// established transactional writer (`ProfileSaveTransaction`) in production —
/// never a weaker direct write. Profile content (directives, raw/unsupported
/// lines) round-trips through `ProfileDocument`.
enum BulkLogPropagation {

    /// A per-profile failure. Carries the profile's base name and an actionable,
    /// non-path-leaking message.
    struct Failure: Equatable {
        let profile: String
        let message: String
    }

    /// Structured accounting of one propagation pass.
    struct Result: Equatable {
        var scanned = 0                    // `.prf` files examined
        var eligible = 0                   // scanned AND `log = true`
        var unchanged = 0                  // eligible but already correct
        var updated: [String] = []         // base names successfully rewritten
        var readFailures: [Failure] = []
        var writeFailures: [Failure] = []
        var enumerationFailed = false      // could not list the profile directory
    }

    /// The five mutually-exclusive user-facing outcomes.
    enum Outcome: Equatable {
        case cannotEnumerate
        case nothingNeeded
        case completeSuccess(updated: Int)
        case partialSuccess(updated: Int, failures: [Failure])
        case completeFailure(failures: [Failure])
    }

    /// Pure classification of a `Result` into exactly one `Outcome`.
    static func classify(_ r: Result) -> Outcome {
        if r.enumerationFailed { return .cannotEnumerate }
        let failures = r.readFailures + r.writeFailures
        if r.updated.isEmpty && failures.isEmpty { return .nothingNeeded }
        if failures.isEmpty { return .completeSuccess(updated: r.updated.count) }
        if r.updated.isEmpty { return .completeFailure(failures: failures) }
        return .partialSuccess(updated: r.updated.count, failures: failures)
    }

    /// Pure presentation model: an alert title + body for an `Outcome`. Lists
    /// failed profile NAMES (not full paths) so a partial/total failure is
    /// reported precisely without leaking sensitive filesystem paths.
    static func present(_ outcome: Outcome) -> (title: String, body: String) {
        func lines(_ fs: [Failure]) -> String {
            fs.map { "• \($0.profile): \($0.message)" }.joined(separator: "\n")
        }
        switch outcome {
        case .cannotEnumerate:
            return ("Couldn’t update profiles",
                    "The Unison profile folder could not be read, so no profiles were changed.")
        case .nothingNeeded:
            return ("No profiles needed updating",
                    "Every profile with logging on already matches the shared location.")
        case .completeSuccess(let n):
            return (n == 1 ? "1 profile updated" : "\(n) profiles updated",
                    "Their log file setting now matches the shared location.")
        case .partialSuccess(let n, let fs):
            let updatedText = n == 1 ? "1 profile was updated" : "\(n) profiles were updated"
            return ("Some profiles could not be updated",
                    "\(updatedText); \(fs.count) could not be changed and were left as-is:\n\(lines(fs))")
        case .completeFailure(let fs):
            return ("No profiles could be updated",
                    "No changes were saved. \(fs.count) profile(s) failed:\n\(lines(fs))")
        }
    }

    /// The propagation engine. All IO is injected:
    /// - `listProfileFileNames`: directory listing, or `nil` on enumeration failure.
    /// - `read`: profile contents by file name, or `nil` on read failure.
    /// - `write`: persist new content for a file name; returns an `Error` on
    ///   failure or `nil` on success (production wires this to the transactional
    ///   writer). Only ever called for a profile that genuinely changed.
    /// - `defaultLogName`: pure helper for a profile's default log file name.
    static func run(
        mode: SettingsModel.LoggingMode,
        sharedFile: String,
        sharedDirectory: String,
        defaultLogName: (String) -> String,
        listProfileFileNames: () -> [String]?,
        read: (String) -> String?,
        write: (_ fileName: String, _ content: String) -> Error?
    ) -> Result {
        var r = Result()
        guard let names = listProfileFileNames() else {
            r.enumerationFailed = true
            return r
        }
        for file in names where (file as NSString).pathExtension == "prf" {
            r.scanned += 1
            let base = (file as NSString).deletingPathExtension
            guard let text = read(file) else {
                r.readFailures.append(Failure(profile: base, message: "could not read the profile file"))
                continue
            }
            var doc = ProfileDocument.parse(text)
            guard doc.firstValue(forKey: "log") == "true" else { continue }   // logging off → not eligible
            r.eligible += 1

            let newLogfile: String
            switch mode {
            case .sameFile:
                newLogfile = sharedFile
            case .sameDirectory:
                let existing = doc.firstValue(forKey: "logfile") ?? ""
                let name = existing.isEmpty
                    ? defaultLogName(base)
                    : (existing as NSString).lastPathComponent
                newLogfile = (sharedDirectory as NSString).appendingPathComponent(name)
            case .perProfile:
                continue   // per-profile never propagates; guarded by the caller too
            }

            guard doc.firstValue(forKey: "logfile") != newLogfile else {
                r.unchanged += 1
                continue
            }
            doc.setValue(newLogfile, forKey: "logfile")
            if let err = write(file, doc.serialized) {
                r.writeFailures.append(Failure(profile: base, message: shortMessage(err)))
            } else {
                r.updated.append(base)
            }
        }
        return r
    }

    /// Actionable, non-path-leaking one-liner for a write error.
    static func shortMessage(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "\(error)"
    }
}
