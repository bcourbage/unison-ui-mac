import Foundation

/// Thread-safe append-only logger to a file.
/// Used during early development since GUI apps lose stdout/stderr.
final class TraceLog {
    // nonisolated(unsafe): the class is thread-safe by design (all access
    // funnels through `queue`), but Swift can't infer Sendability because
    // ISO8601DateFormatter isn't Sendable.
    nonisolated(unsafe) static let shared = TraceLog(path: "/tmp/unison-ui-mac.log")

    private let url: URL
    private let queue = DispatchQueue(label: "TraceLog")
    private let formatter: ISO8601DateFormatter

    init(path: String) {
        self.url = URL(fileURLWithPath: path)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = fmt
        try? Data().write(to: url)
    }

    func write(_ message: String) {
        queue.async { [url, formatter] in
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
