import Foundation

/// Decisions for the two entry points into Check Remote Command that live
/// outside the Profile Editor: the offer after a failed connection and the
/// profile picker's context menu.
enum RemoteCheckOfferPolicy {

    /// A restart-required notice offers the check only when the failure
    /// happened while connecting and the profile has an ssh root: a scan or
    /// sync failure says nothing about the remote command, a local-only
    /// profile has none, and a socket root runs no ssh command either. The
    /// offer is a diagnostic, not a claim that the remote command caused the
    /// failure.
    static func offers(failedWhileConnecting: Bool, roots: [String]) -> Bool {
        guard failedWhileConnecting else { return false }
        return roots.contains { (try? UnisonRoot.parse($0))?.isSSH ?? false }
    }

    /// The effective roots of a profile as Unison would read them; empty when
    /// the profile does not load.
    static func roots(profile: String, unisonDirectory: String) -> [String] {
        guard case .success(let e) = EffectiveProfile.load(profile: profile, unisonDirectory: unisonDirectory) else { return [] }
        return e.list("root").map(\.value)
    }

    /// The editor currently open, if any, as the routing needs to tell apart:
    /// none, a saved profile by name, or an unsaved new profile (which has no
    /// name yet but still holds work).
    enum OpenEditor: Equatable {
        case none
        case named(String)
        case unsavedNewProfile
    }

    /// How an entry point reaches the editor. An editor already open on the
    /// same profile is reused as it stands, so unsaved edits survive; one open
    /// on another profile, or on an unsaved new profile, is left alone, since
    /// replacing it would discard its edits.
    enum EditorRoute: Equatable {
        case openNew
        case reuseOpen
        case blockedBy(String)
        case blockedByNewProfile
    }

    static func route(open: OpenEditor, target: String) -> EditorRoute {
        switch open {
        case .none: return .openNew
        case .named(let p): return p == target ? .reuseOpen : .blockedBy(p)
        case .unsavedNewProfile: return .blockedByNewProfile
        }
    }
}
