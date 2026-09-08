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
        let root: UnisonRoot
        switch RootRules.evaluate(roots: inputs.roots) {
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
                                      addversionno: effective.bool("addversionno") ?? false)
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

    /// Whether the configuration a check started with is still the one the
    /// form and the files describe. Runs a fresh resolution.
    static func tokenStillValid(_ p: Prepared,
                                read: @escaping (String) -> ProfileRootResolver.ReadResult = ProfileRootResolver.filesystemRead) -> Bool {
        guard case .success(let e) = EffectiveProfile.load(profile: p.inputs.profile, unisonDirectory: p.inputs.unisonDirectory, read: read) else {
            return false
        }
        let fresh = RemoteCheckToken.make(
            form: .init(roots: p.inputs.roots, servercmd: p.inputs.servercmd, sshcmd: p.inputs.sshcmd,
                        sshargs: p.inputs.sshargs, addversionno: p.settings.addversionno),
            effective: e, sessionID: p.inputs.sessionID)
        return fresh == p.token
    }

    // MARK: - Step 2 and 3

    enum MenuItem: Equatable {
        /// Non-selectable first line when the field is empty.
        case currentEffect(String)
        case candidate(path: String, versionLine: String?, storedTarget: String?)
        case keepCurrent
    }

    struct Discovery: Equatable {
        let record: RemoteDiscovery.Record?
        let observation: RemoteVerification.Observation
        let menu: [MenuItem]
        /// Failure sentences when the session did not produce a complete record.
        let failureSentences: [String]
        var succeeded: Bool { record?.complete == true }
    }

    typealias ExecutorFactory = (@escaping @Sendable (pid_t) -> Void) -> VersionCheck.VersionProbeExecutor

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
                return Discovery(record: record, observation: observation, menu: menu(for: p, record: record), failureSentences: [])
            }
        }
        return Discovery(record: nil, observation: observation, menu: [],
                         failureSentences: RemoteCheckWording.failure(observation, executablePath: nil, discovery: nil))
    }

    static func menu(for p: Prepared, record: RemoteDiscovery.Record) -> [MenuItem] {
        var items: [MenuItem] = []
        if p.settings.servercmd.isEmpty {
            items.append(.currentEffect("Remote PATH decides which unison runs"))
        }
        for c in record.present {
            var stored: String?
            if case .symlink(let target) = c.kind { stored = target }
            items.append(.candidate(path: c.path, versionLine: c.versionLine, storedTarget: stored))
        }
        items.append(.keepCurrent)
        return items
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
                ? "This check found no change to make."
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
