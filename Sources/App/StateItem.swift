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

    func with(direction newDirection: String) -> StateItem {
        StateItem(path: path, left: left, right: right,
                  direction: newDirection, sizeBytes: sizeBytes, fileType: fileType,
                  progress: progress, bytesTransferred: bytesTransferred)
    }

    func with(progress newProgress: String, bytesTransferred newBytes: Int64) -> StateItem {
        StateItem(path: path, left: left, right: right,
                  direction: direction, sizeBytes: sizeBytes, fileType: fileType,
                  progress: newProgress, bytesTransferred: newBytes)
    }
}
