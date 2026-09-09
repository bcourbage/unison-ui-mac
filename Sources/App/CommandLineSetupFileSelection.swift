import Foundation

// Which startup file the app would edit for an account's login shell, and whether
// it may edit automatically. See docs/command-line-setup-design.md, "Selecting
// the file" and the zsh bound there.
//
// Login shell and home directory come from the account record (getpwuid), never
// from $SHELL or the launching environment. The pure decisions live here; the
// account record, the /etc reads, the launchd ZDOTDIR query and the fish probe
// are supplied by CommandLineSetupProbe.

enum CommandLineSetupShellKind: Equatable, Sendable {
    case zsh, bash, fish, other

    /// The kind of a login shell from its path's last component.
    static func of(loginShellPath: String) -> CommandLineSetupShellKind {
        switch (loginShellPath as NSString).lastPathComponent {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        default: return .other
        }
    }
}

/// Whether `ZDOTDIR` is set for the account, as read from the launchd user
/// environment. A failed or unparsable query is uncertainty, not absence.
enum CommandLineSetupZDOTDIRState: Equatable {
    case absent, present, uncertain
}

/// The file the app would edit, and whether it may do so automatically.
struct CommandLineSetupFileChoice: Equatable, Sendable {
    let shell: CommandLineSetupShellKind
    /// The file the app would write, or nil for an unsupported shell.
    let file: String?
    /// Whether the app may edit automatically. When false, `manualReason` says why.
    let automatic: Bool
    /// Whether `file` is the ESTABLISHED destination, not merely the usual name.
    /// zsh keeps `~/.zprofile` as `file` even when `ZDOTDIR` or a `.zshenv`
    /// redirect makes it uncertain which file the login shell reads; in that case
    /// this is false, and Manual setup must not instruct the user to edit `file`
    /// or offer Copy Setup Text for it.
    let destinationEstablished: Bool
    /// The single-line reason the file is Manual setup, or nil when automatic.
    let manualReason: String?
    /// bash only: create the named file if none of the candidates exists.
    let createIfAbsent: Bool
}

enum CommandLineSetupFileSelection {

    // MARK: Known stock /etc/zprofile texts

    /// The stock `/etc/zprofile` measured on macOS 26.6.2 (build 25G83): a
    /// `LANG=C.UTF-8` default and the `path_helper` eval, nothing else. The
    /// macOS 15 text is captured and added by the release pipeline's macOS 15 job.
    /// A macOS revision that changes the file moves accounts to Manual setup until
    /// its text is measured and added; that refusal is intended, not a defect.
    static let stockZprofileMacOS26 = [
        "# System-wide profile for interactive zsh(1) login shells.",
        "",
        "# Setup user specific overrides for this in ~/.zprofile. See zshbuiltins(1)",
        "# and zshoptions(1) for more details.",
        "",
        "if [ -z \"$LANG\" ]; then",
        "\texport LANG=C.UTF-8",
        "fi",
        "",
        "if [ -x /usr/libexec/path_helper ]; then",
        "\teval `/usr/libexec/path_helper -s`",
        "fi",
        "",
    ].joined(separator: "\n")

    static let knownStockZprofileTexts: [String] = [stockZprofileMacOS26]

    // MARK: zsh bound

    /// Whether zsh's `$HOME/.zprofile` may be edited automatically: the stock
    /// layout established positively. Any failure is Manual setup.
    static func zshAutomatic(etcZshenvExists: Bool,
                             homeZshenvExists: Bool,
                             etcZprofileContents: String?,
                             zdotdir: CommandLineSetupZDOTDIRState,
                             zdotdirInAppEnvironment: Bool) -> Bool {
        guard !etcZshenvExists, !homeZshenvExists else { return false }
        guard let contents = etcZprofileContents,
              knownStockZprofileTexts.contains(contents) else { return false }
        guard zdotdir == .absent, !zdotdirInAppEnvironment else { return false }
        return true
    }

    static func zshManualReason(etcZshenvExists: Bool,
                                homeZshenvExists: Bool,
                                etcZprofileContents: String?,
                                zdotdir: CommandLineSetupZDOTDIRState,
                                zdotdirInAppEnvironment: Bool) -> String {
        if etcZshenvExists || homeZshenvExists {
            return "a .zshenv file is present, which the app cannot account for, so setup is manual"
        }
        if etcZprofileContents == nil {
            return "/etc/zprofile could not be read, so setup is manual"
        }
        if !knownStockZprofileTexts.contains(etcZprofileContents!) {
            return "/etc/zprofile differs from the version the app recognizes, so setup is manual"
        }
        if zdotdir == .present || zdotdirInAppEnvironment {
            return "ZDOTDIR is set, which moves zsh's startup files, so setup is manual"
        }
        return "the zsh startup layout could not be established, so setup is manual"
    }

    // MARK: Selection

    /// The file choice for zsh, given the bound inputs and the home directory.
    static func zshChoice(homeDirectory: String,
                          etcZshenvExists: Bool,
                          homeZshenvExists: Bool,
                          etcZprofileContents: String?,
                          zdotdir: CommandLineSetupZDOTDIRState,
                          zdotdirInAppEnvironment: Bool) -> CommandLineSetupFileChoice {
        let file = (homeDirectory as NSString).appendingPathComponent(".zprofile")
        let automatic = zshAutomatic(etcZshenvExists: etcZshenvExists, homeZshenvExists: homeZshenvExists,
                                     etcZprofileContents: etcZprofileContents, zdotdir: zdotdir,
                                     zdotdirInAppEnvironment: zdotdirInAppEnvironment)
        // ~/.zprofile is the established destination only under the full stock
        // bound. A non-stock or unreadable /etc/zprofile can itself set ZDOTDIR
        // before zsh reads the user file, so it too leaves the destination
        // uncertain; only the complete bound (which `automatic` already checks)
        // establishes that zsh reads ~/.zprofile.
        let destinationEstablished = automatic
        return CommandLineSetupFileChoice(
            shell: .zsh, file: file, automatic: automatic, destinationEstablished: destinationEstablished,
            manualReason: automatic ? nil : zshManualReason(
                etcZshenvExists: etcZshenvExists, homeZshenvExists: homeZshenvExists,
                etcZprofileContents: etcZprofileContents, zdotdir: zdotdir,
                zdotdirInAppEnvironment: zdotdirInAppEnvironment),
            createIfAbsent: false)
    }

    /// bash reads the first existing of `~/.bash_profile`, `~/.bash_login`,
    /// `~/.profile`; if none exists, `~/.bash_profile` is created. When one exists
    /// but cannot be read, setup is manual. `existing` maps each candidate to
    /// whether it exists, `readable` to whether it can be read.
    static func bashChoice(homeDirectory: String,
                           existing: (String) -> Bool,
                           readable: (String) -> Bool) -> CommandLineSetupFileChoice {
        let candidates = [".bash_profile", ".bash_login", ".profile"].map {
            (homeDirectory as NSString).appendingPathComponent($0)
        }
        for candidate in candidates where existing(candidate) {
            if readable(candidate) {
                return CommandLineSetupFileChoice(shell: .bash, file: candidate, automatic: true,
                                                  destinationEstablished: true,
                                                  manualReason: nil, createIfAbsent: false)
            }
            return CommandLineSetupFileChoice(
                shell: .bash, file: candidate, automatic: false, destinationEstablished: true,
                manualReason: "a bash startup file exists but could not be read, so setup is manual",
                createIfAbsent: false)
        }
        // None exists: create ~/.bash_profile.
        return CommandLineSetupFileChoice(shell: .bash, file: candidates[0], automatic: true,
                                          destinationEstablished: true,
                                          manualReason: nil, createIfAbsent: true)
    }

    /// fish edits `<config dir>/conf.d/unison-ui-mac.fish` only when the probe
    /// reported an ABSOLUTE, EXISTING directory (the design's requirement).
    /// `directoryExists` is injected so the existence check is established here, at
    /// the selection layer, rather than assumed from the string alone.
    static func fishChoice(configDirectory: String?,
                           directoryExists: (String) -> Bool) -> CommandLineSetupFileChoice {
        guard let dir = configDirectory else {
            return CommandLineSetupFileChoice(
                shell: .fish, file: nil, automatic: false, destinationEstablished: false,
                manualReason: "the fish configuration directory could not be determined, so setup is manual",
                createIfAbsent: true)
        }
        guard dir.hasPrefix("/"), directoryExists(dir) else {
            return CommandLineSetupFileChoice(
                shell: .fish, file: nil, automatic: false, destinationEstablished: false,
                manualReason: "the fish configuration directory is not an absolute existing directory, so setup is manual",
                createIfAbsent: true)
        }
        let file = (dir as NSString).appendingPathComponent("conf.d/unison-ui-mac.fish")
        return CommandLineSetupFileChoice(shell: .fish, file: file, automatic: true,
                                          destinationEstablished: true,
                                          manualReason: nil, createIfAbsent: true)
    }

    static func otherChoice() -> CommandLineSetupFileChoice {
        CommandLineSetupFileChoice(
            shell: .other, file: nil, automatic: false, destinationEstablished: false,
            manualReason: "this login shell is not one the app edits automatically, so setup is manual",
            createIfAbsent: false)
    }
}
