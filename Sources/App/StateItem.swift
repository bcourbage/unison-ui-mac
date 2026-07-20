import Foundation

/// Swift-side mirror of the bridge's `unison_state_item_t`. Plain value
/// type — once we receive the array from OCaml we copy the strings in
/// (via String(cString:)) and the bridge's C-owned memory can be freed.
struct StateItem: Sendable, Equatable {
    let path: String
    let left: String
    let right: String
    let direction: String
    let sizeBytes: Int64
    let fileType: String
    let progress: String
    let bytesTransferred: Int64
    /// Whether the row's current direction differs from Unison's post-scan
    /// recommendation (engine `changedFromDefault`). Carried from the engine
    /// because Swift cannot compute it from the direction string alone — a
    /// skip-requested Conflict renders identically to a default Conflict yet is
    /// "changed". Currently drives Revert eligibility.
    let changedFromDefault: Bool

    /// No default for `changedFromDefault`: it is a load-bearing engine fact, so
    /// every construction site must state it explicitly (a silent `false` on a
    /// real row would hide a divergence and mis-gate Revert). Bridge rows carry
    /// the engine value; synthetic/test rows pass it deliberately.
    init(path: String, left: String, right: String, direction: String,
         sizeBytes: Int64, fileType: String, progress: String,
         bytesTransferred: Int64, changedFromDefault: Bool) {
        self.path = path
        self.left = left
        self.right = right
        self.direction = direction
        self.sizeBytes = sizeBytes
        self.fileType = fileType
        self.progress = progress
        self.bytesTransferred = bytesTransferred
        self.changedFromDefault = changedFromDefault
    }

    /// Update the direction and the engine-divergence flag together — a direction
    /// change must ALWAYS supply the corresponding `changedFromDefault` (there is
    /// deliberately no direction-only updater, which could desync the two).
    func with(direction newDirection: String, changedFromDefault newChanged: Bool) -> StateItem {
        StateItem(path: path, left: left, right: right,
                  direction: newDirection, sizeBytes: sizeBytes, fileType: fileType,
                  progress: progress, bytesTransferred: bytesTransferred,
                  changedFromDefault: newChanged)
    }

    func with(progress newProgress: String, bytesTransferred newBytes: Int64) -> StateItem {
        StateItem(path: path, left: left, right: right,
                  direction: direction, sizeBytes: sizeBytes, fileType: fileType,
                  progress: newProgress, bytesTransferred: newBytes,
                  changedFromDefault: changedFromDefault)
    }
}
