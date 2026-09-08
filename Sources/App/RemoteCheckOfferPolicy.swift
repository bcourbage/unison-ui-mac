import Foundation

/// Decisions for the two entry points into Check Remote Command that live
/// outside the Profile Editor: the offer after a failed connection and the
/// profile picker's context menu.
enum RemoteCheckOfferPolicy {

    /// A restart-required notice offers the check only when the failure
    /// happened while connecting and the profile has an `ssh://` root: a
    /// scan or sync failure says nothing about the remote command, and a
    /// local-only profile has none. The offer is a diagnostic, not a claim
    /// that the remote command caused the failure.
    static func offers(failedWhileConnecting: Bool, roots: [String]) -> Bool {
        guard failedWhileConnecting else { return false }
        return roots.contains { (try? UnisonRoot.parse($0))?.isRemote ?? false }
    }

    /// The effective roots of a profile as Unison would read them; empty when
    /// the profile does not load.
    static func roots(profile: String, unisonDirectory: String) -> [String] {
        guard case .success(let e) = EffectiveProfile.load(profile: profile, unisonDirectory: unisonDirectory) else { return [] }
        return e.list("root").map(\.value)
    }

    /// How an entry point reaches the editor. An editor already open on the
    /// same profile is reused as it stands, so unsaved edits survive; one
    /// open on another profile is left alone and named, since replacing it
    /// would discard its edits.
    enum EditorRoute: Equatable {
        case openNew
        case reuseOpen
        case blockedBy(String)
    }

    static func route(openEditorProfile: String?, target: String) -> EditorRoute {
        guard let open = openEditorProfile else { return .openNew }
        return open == target ? .reuseOpen : .blockedBy(open)
    }
}
