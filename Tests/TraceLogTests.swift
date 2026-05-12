import XCTest
@testable import unison_ui_mac

final class TraceLogTests: XCTestCase {

    private func makeTempPath() -> String {
        let tmp = NSTemporaryDirectory() as NSString
        return tmp.appendingPathComponent("trace-test-\(UUID().uuidString).log")
    }

    func test_write_appendsLineWithTimestampAndMessage() throws {
        let path = makeTempPath()
        let log = TraceLog(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        log.write("hello")
        // TraceLog dispatches asynchronously to its own private queue, so we
        // can't await it directly. Poll the file with a generous deadline.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               !data.isEmpty {
                let s = String(data: data, encoding: .utf8) ?? ""
                XCTAssertTrue(s.contains("hello"), "missing message: \(s)")
                XCTAssertTrue(s.hasSuffix("\n"), "line not newline-terminated")
                // ISO-8601 prefix sanity check
                XCTAssertTrue(s.hasPrefix("20"), "expected ISO-8601 year prefix, got: \(s.prefix(20))")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("TraceLog did not write within 2 seconds")
    }

    func test_concurrentWrites_serializeWithoutCorruption() throws {
        let path = makeTempPath()
        let log = TraceLog(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let n = 200
        let group = DispatchGroup()
        for i in 0..<n {
            group.enter()
            DispatchQueue.global().async {
                log.write("line \(i)")
                group.leave()
            }
        }
        group.wait()

        // Drain — same poll pattern.
        let deadline = Date().addingTimeInterval(3.0)
        var contents = ""
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               !data.isEmpty {
                contents = String(data: data, encoding: .utf8) ?? ""
                let lineCount = contents.split(separator: "\n").count
                if lineCount >= n { break }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, n, "expected \(n) lines, got \(lines.count)")
        // Every line should contain "line " — no torn writes.
        for line in lines {
            XCTAssertTrue(line.contains("line "), "torn line: \(line)")
        }
    }
}
