import Foundation

/// One guided remote check, driven from the Profile Editor's form values:
/// Step 1 (effective settings and root rules), Step 2 (discovery session),
/// Step 3 (menu of candidates), Step 4 (verification session) and Step 5
/// (result sentences). The editor owns the UI and the token comparison at
/// completion; this type owns the composition and the sentences.
enum RemoteCheckFlow {

    struct Inputs: Equatable {
        var profile: String
        var unisonDirectory: String
        /// The form's values as shown: roots, Remote unison, SSH command, SSH args.
        var roots: [String]
        var servercmd: String
        var sshcmd: String
        var sshargs: String
        /// The values of the form's Advanced `addversionno = …` lines, in order
        /// (empty when Advanced has none). The pending effective value is
        /// derived from these and the includes; see `pendingAddversionno`.
        var addversionnoAdvanced: [String] = []
        /// The same values as the editor loaded them. Save treats a changed
        /// assignment differently from an untouched one; so does the check.
        var addversionnoAdvancedAtLoad: [String] = []
        /// The local engine's version string, as `unison_bridge_get_version` reports it.
        var localEngineVersion: String
        var sessionID: UUID
        var deadline: TimeInterval = RemoteCheckSession.defaultDeadline
    }

    enum StartFailure: Error, Equatable {
        /// Unison would not load the profile, or the check could not establish it; Unison's message.
        case profile(String)
        /// A root rule failed; upstream's message.
        case roots(String)
        case notApplicable(RootRules.NotApplicable)
        case shellCommandNotFound(name: String, searched: [String])
        case localVersion(String)
    }

    struct Prepared {
        let effective: EffectiveProfile
        let settings: RemoteSettings
        let root: UnisonRoot
        let command: RemoteCommand
        /// The ssh executable to launch.
        let executable: String
        let token: RemoteCheckToken
        let majorVersion: String
        let localVersion: String
        let inputs: Inputs

        var host: String { if case .shell(_, let h, _, _, _) = root { return h }; return "" }
        var user: String? { if case .shell(_, _, let u, _, _) = root { return u }; return nil }
    }

    /// Step 1. Pure apart from reading the profile files.
    static func prepare(_ inputs: Inputs,
                        read: @escaping (String) -> ProfileRootResolver.ReadResult = ProfileRootResolver.filesystemRead,
                        shellExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> Result<Prepared, StartFailure>
    {
        let effective: EffectiveProfile
        switch EffectiveProfile.load(profile: inputs.profile, unisonDirectory: inputs.unisonDirectory, read: read) {
        case .success(let e): effective = e
        case .failure(let err): return .failure(.profile(err.message))
        }
        // Upstream's root rules apply to the effective root list: the form's two
        // roots stand in for the top-level file's, and roots from includes stay.
        let root: UnisonRoot
        switch RootRules.evaluate(roots: pendingRoots(inputs: inputs, effective: effective)) {
        case .failure(.fatal(let m)): return .failure(.roots(m))
        case .success(.notApplicable(let why)): return .failure(.notApplicable(why))
        case .success(.ssh(let remote, _)): root = remote
        }
        guard let localVersion = VersionCheck.parseVersionString(inputs.localEngineVersion),
              let major = RemoteCommand.majorVersion(fromEngineVersion: inputs.localEngineVersion) else {
            return .failure(.localVersion(inputs.localEngineVersion))
        }
        let settings = RemoteSettings(servercmd: inputs.servercmd,
                                      sshcmd: inputs.sshcmd.isEmpty ? "ssh" : inputs.sshcmd,
                                      sshargs: inputs.sshargs,
                                      addversionno: pendingAddversionno(inputs: inputs, effective: effective))
        guard let command = RemoteCommand.compose(settings: settings, root: root, majorVersion: major) else {
            return .failure(.notApplicable(.noRemoteRoot))
        }
        let executable: String
        switch RemoteCheckSession.resolveShellCommand(settings.sshcmd, fileExists: shellExists) {
        case .resolved(let path): executable = path
        case .notFound(let name, let searched): return .failure(.shellCommandNotFound(name: name, searched: searched))
        }
        let token = RemoteCheckToken.make(
            form: .init(roots: inputs.roots, servercmd: inputs.servercmd, sshcmd: inputs.sshcmd,
                        sshargs: inputs.sshargs, addversionno: settings.addversionno),
            effective: effective, sessionID: inputs.sessionID)
        return .success(Prepared(effective: effective, settings: settings, root: root, command: command,
                                 executable: executable, token: token, majorVersion: major,
                                 localVersion: localVersion, inputs: inputs))
    }

    /// The effective root list the pending profile would have: every root from
    /// the includes in spliced order, with the top-level file's roots replaced
    /// by the form's at their position (or appended when the top-level file has
    /// none, which is where a save would put them).
    static func pendingRoots(inputs: Inputs, effective: EffectiveProfile) -> [String] {
        let top = effective.files.first ?? ""
        var out: [String] = []
        var placed = false
        for a in effective.list("root") {
            if ProfileScalarSemantics.samePath(a.location.path, top) {
                if !placed { out += inputs.roots; placed = true }
            } else {
                out.append(a.value)
            }
        }
        if !placed { out += inputs.roots }
        return out
    }

    /// The `addversionno` the pending profile would have once saved, by the
    /// rules Save applies. A changed Advanced assignment is placed so it wins
    /// over any include: its last value is the answer. Otherwise the Advanced
    /// lines stand in for the top-level file's assignments at their position
    /// (the Advanced reconciler writes at the first previous occurrence, or the
    /// end when there was none), assignments from includes stay, and the last
    /// one wins. No assignment anywhere is Unison's default, false.
    static func pendingAddversionno(inputs: Inputs, effective: EffectiveProfile) -> Bool {
        if inputs.addversionnoAdvanced != inputs.addversionnoAdvancedAtLoad, let last = inputs.addversionnoAdvanced.last {
            return last == "true"
        }
        let top = effective.files.first ?? ""
        var values: [String] = []
        var placed = false
        for a in effective.list("addversionno") {
            if ProfileScalarSemantics.samePath(a.location.path, top) {
                if !placed { values += inputs.addversionnoAdvanced; placed = true }
            } else {
                values.append(a.value)
            }
        }
        if !placed { values += inputs.addversionnoAdvanced }
        return values.last == "true"
    }

    /// Whether the configuration a check started with is still the one the
    /// form and the files describe: a fresh resolution and the form's current
    /// values (`current`, which may differ from the inputs the check began
    /// with) must reproduce the token.
    static func tokenStillValid(_ p: Prepared, current: Inputs? = nil,
                                read: @escaping (String) -> ProfileRootResolver.ReadResult = ProfileRootResolver.filesystemRead) -> Bool {
        let i = current ?? p.inputs
        guard case .success(let e) = EffectiveProfile.load(profile: i.profile, unisonDirectory: i.unisonDirectory, read: read) else {
            return false
        }
        let fresh = RemoteCheckToken.make(
            form: .init(roots: i.roots, servercmd: i.servercmd, sshcmd: i.sshcmd, sshargs: i.sshargs,
                        addversionno: pendingAddversionno(inputs: i, effective: e)),
            effective: e, sessionID: i.sessionID)
        return fresh == p.token
    }

    // MARK: - Step 2 and 3

    // MARK: - Step 3: the current command first, then alternatives

    /// One line of the Choose Another Command menu. The current setting is
    /// verified first; these rows are offered only when the user wants a
    /// different installation, and each states the consequence of choosing
    /// it, not a maintenance policy the check cannot see.
    struct AlternativeRow: Equatable {
        enum Kind: Equatable { case header, keepCurrent, direct, link }
        let kind: Kind
        let title: String
        /// The full path shown under the title; nil for a header and for a
        /// current setting the remote PATH decides.
        let path: String?
        let subtitle: String
        /// The path Step 4 verifies when this row is chosen; nil for a header
        /// and for Keep current setting.
        var selectionPath: String? { (kind == .direct || kind == .link) ? path : nil }
    }

    static func alternatives(for p: Prepared, record: RemoteDiscovery.Record) -> [AlternativeRow] {
        let current = p.settings.servercmd
        let currentWord = p.command.remoteExecutableWords.first ?? ""
        func versionClause(_ line: String?) -> String {
            guard let line, let remote = VersionCheck.parseUnisonVersionLine(line) else { return "No version reported." }
            if case .incompatibleAcrossBoundary = VersionCheck.classify(local: p.localVersion, remote: remote) {
                return "Version \(remote), cannot connect to this Mac's \(p.localVersion)."
            }
            return "Version \(remote)."
        }
        /// The installation a path reaches, for grouping. Only the remote's own
        /// resolution (realpath / readlink -f) is trusted: resolving a stored
        /// symlink target lexically here can cross an intermediate symlink and
        /// assert a false equivalence, so without a remote resolution a path is
        /// its own identity and is not grouped.
        func identity(_ c: RemoteDiscovery.Candidate) -> String {
            c.resolvedPath ?? c.path
        }
        let usable = record.present.filter { c in
            switch c.kind { case .regular, .symlink: return true; case .directory, .other: return false }
        }
        let currentCandidate = usable.first { $0.path == currentWord }
        let others = usable.filter { $0.path != currentWord }
        var groups: [(key: String, members: [RemoteDiscovery.Candidate])] = []
        for c in (currentCandidate.map { [$0] } ?? []) + others {
            let key = identity(c)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].members.append(c) } else { groups.append((key, [c])) }
        }
        func row(_ c: RemoteDiscovery.Candidate, group: [RemoteDiscovery.Candidate]) -> AlternativeRow {
            switch c.kind {
            case .symlink(let target):
                return AlternativeRow(kind: .link, title: "Use the command link", path: c.path,
                                      subtitle: "Uses whichever installation this link points to; now \(target). " + versionClause(c.versionLine))
            default:
                let linked = group.count > 1 && group.contains { if case .symlink = $0.kind { return true }; return false }
                let effect = linked ? "Uses the program at this location, even if the link is redirected. "
                                    : "Uses the program at this location. "
                return AlternativeRow(kind: .direct, title: "Use this installation directly", path: c.path,
                                      subtitle: effect + versionClause(c.versionLine))
            }
        }
        let keep = AlternativeRow(kind: .keepCurrent, title: "Keep current setting", path: current.isEmpty ? nil : current,
                                  subtitle: current.isEmpty
                                      ? "No command is set for this profile; the remote PATH decides which unison runs."
                                      : "Currently configured for this profile.")
        var rows: [AlternativeRow] = []
        var keepPlaced = false
        for g in groups {
            if g.members.count > 1 {
                rows.append(AlternativeRow(kind: .header, title: g.members.count == 2 ? "Two paths to the same installation"
                                                                                     : "\(g.members.count) paths to the same installation",
                                           path: nil, subtitle: ""))
            }
            if g.members.contains(where: { $0.path == currentWord }) { rows.append(keep); keepPlaced = true }
            for c in g.members where c.path != currentWord { rows.append(row(c, group: g.members)) }
        }
        if !keepPlaced { rows.insert(keep, at: 0) }
        return rows
    }

    /// The help shown beside the button.
    static let helpText: [String] = [
        "Which command should I use?",
        "If your current command passes the check, you usually do not need to change it.",
        "Choose another command when you want this profile to use a different installation on the remote server. Some paths are links and may later point to another installation.",
        "This check reads the command's version. Run a synchronization to confirm that the two installations work together.",
    ]

    struct Discovery: Equatable {
        let record: RemoteDiscovery.Record?
        let observation: RemoteVerification.Observation
        /// The Choose Another Command rows (see `alternatives`); empty when
        /// discovery failed.
        let rows: [AlternativeRow]
        /// Failure sentences when the session did not produce a complete record.
        let failureSentences: [String]
        var succeeded: Bool { record?.complete == true }
    }

    typealias ExecutorFactory = @Sendable (@escaping @Sendable (pid_t) -> Void) -> VersionCheck.VersionProbeExecutor

    static func defaultExecutor(_ onLaunch: @escaping @Sendable (pid_t) -> Void) -> VersionCheck.VersionProbeExecutor {
        VersionCheck.SubprocessProbeExecutor(onLaunch: onLaunch)
    }

    static func discover(_ p: Prepared, handle: RemoteCheckSession.Handle,
                         makeExecutor: ExecutorFactory = RemoteCheckFlow.defaultExecutor) async -> Discovery {
        let word = p.command.remoteExecutableWords.first ?? RemoteCommand.defaultServerName
        let plan = RemoteDiscovery.plan(effectiveExecutable: word)
        let marker = RemoteCheckSession.makeMarker(prefix: "unison-ui-mac-discover")
        let remote = RemoteDiscovery.remoteCommand(marker: marker, plan: plan)
        let config = RemoteCheckSession.probeConfig(command: p.command, executable: p.executable, remoteCommand: remote)
        let raw = await RemoteCheckSession.run(config: config, deadline: p.inputs.deadline, handle: handle, makeExecutor: makeExecutor)
        let observation = RemoteVerification.observe(raw: raw, marker: marker, deadline: p.inputs.deadline)
        if case .exited(0) = observation.termination, case .exited(_, let stdout, _) = raw {
            let record = RemoteDiscovery.parse(stdout: stdout, marker: marker)
            if record.complete {
                return Discovery(record: record, observation: observation, rows: alternatives(for: p, record: record), failureSentences: [])
            }
        }
        return Discovery(record: nil, observation: observation, rows: [],
                         failureSentences: RemoteCheckWording.failure(observation, executablePath: nil, discovery: nil))
    }

    // MARK: - Step 4 and 5

    enum Selection: Equatable {
        case keepCurrent
        case candidate(String)
    }

    struct Verification: Equatable {
        let verdict: RemoteVerification.Verdict
        let observation: RemoteVerification.Observation?
        /// The first sentence shown under the field.
        let headline: String
        /// Sentences for the Details popover (connection, program, version, PATH).
        let details: [String]
        let closing: String
        /// The `servercmd` value to put in the field when a candidate was verified and compatible.
        let proposal: ServercmdProposal.Proposal?
        /// Set when the selected path could not be proposed; no session ran.
        let proposalRefusal: ServercmdProposal.Refusal?
        /// Nil until a version was parsed.
        let compatible: Bool?
    }

    static func verify(_ p: Prepared, selection: Selection, discovery: RemoteDiscovery.Record?,
                       handle: RemoteCheckSession.Handle,
                       makeExecutor: ExecutorFactory = RemoteCheckFlow.defaultExecutor) async -> Verification {
        var settings = p.settings
        var proposal: ServercmdProposal.Proposal?
        if case .candidate(let path) = selection {
            switch ServercmdProposal.compose(selectedPath: path, addversionno: p.settings.addversionno, majorVersion: p.majorVersion) {
            case .success(let prop):
                proposal = prop
                settings.servercmd = prop.servercmd
                if prop.setsAddversionnoFalse { settings.addversionno = false }
            case .failure(let refusal):
                let why: String
                switch refusal {
                case .unsafeCharacters(let chars):
                    why = "The selected path contains characters the check does not propose (\(chars.joined(separator: " "))). A link with a plain path on the remote, such as /usr/local/bin/unison, can be proposed."
                case .notAbsolute:
                    why = "The selected path is not absolute and is not proposed."
                }
                return Verification(verdict: .notVerified, observation: nil, headline: why, details: [],
                                    closing: RemoteCheckWording.closingAfterFailure, proposal: nil,
                                    proposalRefusal: refusal, compatible: nil)
            }
        }
        guard let command = RemoteCommand.compose(settings: settings, root: p.root, majorVersion: p.majorVersion) else {
            return Verification(verdict: .notVerified, observation: nil, headline: RemoteCheckWording.closingAfterFailure,
                                details: [], closing: RemoteCheckWording.closingAfterFailure, proposal: nil, proposalRefusal: nil, compatible: nil)
        }
        let marker = RemoteCheckSession.makeMarker(prefix: RemoteVerification.markerPrefix)
        let remote = RemoteVerification.remoteCommand(marker: marker, versionCommand: command.versionCommandString)
        let config = RemoteCheckSession.probeConfig(command: command, executable: p.executable, remoteCommand: remote)
        let raw = await RemoteCheckSession.run(config: config, deadline: p.inputs.deadline, handle: handle, makeExecutor: makeExecutor)
        let observation = RemoteVerification.observe(raw: raw, marker: marker, deadline: p.inputs.deadline)
        let verdict = RemoteVerification.verdict(observation)
        let executableWord = command.remoteExecutableWords.first
        switch verdict {
        case .verified(let version, let firstLine):
            let incompatible: Bool
            if case .incompatibleAcrossBoundary = VersionCheck.classify(local: p.localVersion, remote: version) { incompatible = true } else { incompatible = false }
            var details: [String] = [RemoteCheckWording.connection(host: p.host, user: p.user)]
            if let word = executableWord, let c = discovery?.candidate(at: word) {
                details += RemoteCheckWording.executable(c, host: p.host)
            }
            details.append(RemoteCheckWording.versionPrinted(remoteCommand: command.versionCommandString, line: firstLine))
            details.append(RemoteCheckWording.protocolBoundary(local: p.localVersion, remote: version, host: p.host))
            // About the profile as it stands, not the verified candidate.
            if p.settings.servercmd.isEmpty { details.append(RemoteCheckWording.pathDecidedByRemote(host: p.host)) }
            if let record = discovery { details.append(RemoteCheckWording.commandV(record.commandV, host: p.host)) }
            if incompatible {
                let headline = "The command started over ssh and reported version \(version). "
                    + "\(version) (\(p.host)) and \(p.localVersion) (this Mac) are on opposite sides of the 2.52 boundary and cannot connect."
                return Verification(verdict: verdict, observation: observation, headline: headline, details: details,
                                    closing: RemoteCheckWording.closingAfterFailure, proposal: nil, proposalRefusal: nil, compatible: false)
            }
            let headline = selection == .keepCurrent
                ? "No change needed."
                : "The command you selected started over ssh and reported its version."
            return Verification(verdict: verdict, observation: observation, headline: headline, details: details,
                                closing: "Only a synchronization confirms the server protocol; run the profile to test that.",
                                proposal: selection == .keepCurrent ? nil : proposal, proposalRefusal: nil, compatible: true)
        case .cancelled:
            return Verification(verdict: verdict, observation: observation, headline: RemoteCheckWording.cancelled, details: [],
                                closing: "", proposal: nil, proposalRefusal: nil, compatible: nil)
        case .notVerified:
            var sentences = RemoteCheckWording.failure(observation,
                                                       executablePath: executableWord.flatMap { $0.hasPrefix("/") ? $0 : nil },
                                                       discovery: discovery)
            let closing = sentences.last == RemoteCheckWording.closingAfterFailure ? sentences.removeLast() : RemoteCheckWording.closingAfterFailure
            let headline = sentences.isEmpty ? closing : sentences.removeFirst()
            return Verification(verdict: verdict, observation: observation, headline: headline, details: sentences,
                                closing: closing, proposal: nil, proposalRefusal: nil, compatible: nil)
        }
    }
}
