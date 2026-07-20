import Foundation

/// Swift-side mirror of the bridge's `unison_state_item_t`. Plain value
/// type — once we receive the array from OCaml we copy the strings in
/// (via String(cString:)) and the bridge's C-owned memory can be freed.
struct StateItem: Sendable {
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
    /// "changed". Drives the "modified" badge and Revert enablement.
    let changedFromDefault: Bool

    /// Default `changedFromDefault: false` so the many test/UI construction
    /// sites that predate the field keep compiling; real values come from the
    /// bridge trampolines and the direction-action readbacks.
    init(path: String, left: String, right: String, direction: String,
         sizeBytes: Int64, fileType: String, progress: String,
         bytesTransferred: Int64, changedFromDefault: Bool = false) {
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

    func with(direction newDirection: String) -> StateItem {
        StateItem(path: path, left: left, right: right,
                  direction: newDirection, sizeBytes: sizeBytes, fileType: fileType,
                  progress: progress, bytesTransferred: bytesTransferred,
                  changedFromDefault: changedFromDefault)
    }

    /// Update both the direction and the engine-divergence flag together — used
    /// after a direction action or a Revert reports its readback.
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
