import XCTest
@testable import unison_ui_mac

/// Honest bulk logging propagation ("Update All"). The engine produces
/// structured accounting and a pure five-way outcome, so a partial or total
/// failure is never reported as "nothing needed updating". All IO is injected.
final class BulkLogPropagationTests: XCTestCase {

    private typealias BP = BulkLogPropagation
    private func prof(log: Bool, logfile: String?, extra: String = "") -> String {
        var s = "root = /a\nroot = ssh://h//b\n"
        if log { s += "log = true\n" }
        if let lf = logfile { s += "logfile = \(lf)\n" }
        s += extra
        return s
    }

    // MARK: - classify (all five outcomes)

    func test_classify_enumerationFailure_isCannotEnumerate() {
        var r = BP.Result(); r.enumerationFailed = true
        XCTAssertEqual(BP.classify(r), .cannotEnumerate)
    }
    func test_classify_noWorkNoFailures_isNothingNeeded() {
        var r = BP.Result(); r.scanned = 3; r.eligible = 2; r.unchanged = 2
        XCTAssertEqual(BP.classify(r), .nothingNeeded)
    }
    func test_classify_updatesNoFailures_isCompleteSuccess() {
        var r = BP.Result(); r.updated = ["A", "B"]
        XCTAssertEqual(BP.classify(r), .completeSuccess(updated: 2))
    }
    func test_classify_updatesAndFailures_isPartialSuccess() {
        var r = BP.Result(); r.updated = ["A"]
        r.writeFailures = [BP.Failure(profile: "B", message: "x")]
        XCTAssertEqual(BP.classify(r),
                       .partialSuccess(updated: 1, failures: [BP.Failure(profile: "B", message: "x")]))
    }
    func test_classify_onlyFailures_isCompleteFailure() {
        var r = BP.Result()
        r.readFailures = [BP.Failure(profile: "A", message: "r")]
        r.writeFailures = [BP.Failure(profile: "B", message: "w")]
        XCTAssertEqual(BP.classify(r), .completeFailure(failures: [
            BP.Failure(profile: "A", message: "r"), BP.Failure(profile: "B", message: "w")]))
    }

    // MARK: - present differentiates outcomes (the core bug)

    func test_present_cannotEnumerate_isNotNothingNeeded() {
        let enumTitle = BP.present(.cannotEnumerate).title
        let nothingTitle = BP.present(.nothingNeeded).title
        XCTAssertNotEqual(enumTitle, nothingTitle)
        XCTAssertTrue(enumTitle.lowercased().contains("couldn"))
    }
    func test_present_partial_and_completeFailure_listFailedNames_noPaths() {
        let fs = [BP.Failure(profile: "Home", message: "write failed (EACCES)")]
        let partial = BP.present(.partialSuccess(updated: 2, failures: fs)).body
        XCTAssertTrue(partial.contains("Home"))
        XCTAssertTrue(partial.contains("2 profiles were updated"))
        let full = BP.present(.completeFailure(failures: fs)).body
        XCTAssertTrue(full.contains("Home"))
        XCTAssertTrue(full.lowercased().contains("no changes were saved"))
    }

    // MARK: - run() with injected IO

    private func run(_ mode: SettingsModel.LoggingMode,
                     files: [String]?,
                     contents: [String: String],
                     failRead: Set<String> = [],
                     failWrite: Set<String> = [],
                     sharedFile: String = "/shared/all.log",
                     sharedDir: String = "/shared/logs",
                     captured: ((String, String) -> Void)? = nil) -> BP.Result {
        struct WErr: LocalizedError { let errorDescription: String? }
        return BP.run(
            mode: mode, sharedFile: sharedFile, sharedDirectory: sharedDir,
            defaultLogName: { "\($0).log" },
            listProfileFileNames: { files },
            read: { failRead.contains($0) ? nil : contents[$0] },
            write: { file, content in
                if failWrite.contains(file) { return WErr(errorDescription: "write failed (EACCES)") }
                captured?(file, content); return nil
            })
    }

    func test_run_enumerationFailure() {
        let r = run(.sameFile, files: nil, contents: [:])
        XCTAssertTrue(r.enumerationFailed)
        XCTAssertEqual(BP.classify(r), .cannotEnumerate)
    }

    func test_run_allUnchanged_nothingNeeded_noWrites() {
        var wrote = false
        let r = run(.sameFile,
                    files: ["A.prf", "B.prf"],
                    contents: ["A.prf": prof(log: true, logfile: "/shared/all.log"),
                               "B.prf": prof(log: true, logfile: "/shared/all.log")],
                    captured: { _, _ in wrote = true })
        XCTAssertEqual(r.eligible, 2); XCTAssertEqual(r.unchanged, 2)
        XCTAssertTrue(r.updated.isEmpty); XCTAssertFalse(wrote)
        XCTAssertEqual(BP.classify(r), .nothingNeeded)
    }

    func test_run_ineligibleProfilesSkipped() {
        let r = run(.sameFile,
                    files: ["on.prf", "off.prf", "notes.txt"],
                    contents: ["on.prf": prof(log: true, logfile: "/old.log"),
                               "off.prf": prof(log: false, logfile: nil)])
        XCTAssertEqual(r.scanned, 2)          // .txt not scanned
        XCTAssertEqual(r.eligible, 1)         // only on.prf
        XCTAssertEqual(r.updated, ["on"])
    }

    func test_run_completeSuccess() {
        let r = run(.sameFile,
                    files: ["A.prf", "B.prf"],
                    contents: ["A.prf": prof(log: true, logfile: "/old1.log"),
                               "B.prf": prof(log: true, logfile: "/old2.log")])
        XCTAssertEqual(Set(r.updated), ["A", "B"])
        XCTAssertEqual(BP.classify(r), .completeSuccess(updated: 2))
    }

    func test_run_partialSuccess_writeFailureNamedNotSilent() {
        let r = run(.sameFile,
                    files: ["A.prf", "B.prf"],
                    contents: ["A.prf": prof(log: true, logfile: "/old1.log"),
                               "B.prf": prof(log: true, logfile: "/old2.log")],
                    failWrite: ["B.prf"])
        XCTAssertEqual(r.updated, ["A"])
        XCTAssertEqual(r.writeFailures, [BP.Failure(profile: "B", message: "write failed (EACCES)")])
        XCTAssertEqual(BP.classify(r),
                       .partialSuccess(updated: 1, failures: [BP.Failure(profile: "B", message: "write failed (EACCES)")]))
    }

    func test_run_readFailure_isRecordedNotSilent() {
        let r = run(.sameFile,
                    files: ["A.prf", "B.prf"],
                    contents: ["B.prf": prof(log: true, logfile: "/old.log")],
                    failRead: ["A.prf"])
        XCTAssertEqual(r.readFailures, [BP.Failure(profile: "A", message: "could not read the profile file")])
        XCTAssertEqual(r.updated, ["B"])
        XCTAssertEqual(BP.classify(r),
                       .partialSuccess(updated: 1, failures: [BP.Failure(profile: "A", message: "could not read the profile file")]))
    }

    func test_run_completeFailure_allWritesFail() {
        let r = run(.sameFile,
                    files: ["A.prf", "B.prf"],
                    contents: ["A.prf": prof(log: true, logfile: "/o1"),
                               "B.prf": prof(log: true, logfile: "/o2")],
                    failWrite: ["A.prf", "B.prf"])
        XCTAssertTrue(r.updated.isEmpty)
        XCTAssertEqual(r.writeFailures.count, 2)
        if case .completeFailure = BP.classify(r) {} else { XCTFail("expected completeFailure") }
    }

    func test_run_sameDirectory_preservesExistingFilename_orUsesDefault() {
        var writes: [String: String] = [:]
        _ = run(.sameDirectory,
                files: ["Keep.prf", "Fresh.prf"],
                contents: ["Keep.prf": prof(log: true, logfile: "/old/keepme.log"),
                           "Fresh.prf": prof(log: true, logfile: nil)],
                sharedDir: "/shared/logs",
                captured: { writes[$0] = $1 })
        XCTAssertTrue(writes["Keep.prf"]!.contains("logfile = /shared/logs/keepme.log"))
        XCTAssertTrue(writes["Fresh.prf"]!.contains("logfile = /shared/logs/Fresh.log"))
    }

    func test_run_preservesDirectivesAndRawContentThroughProfileDocument() {
        let extra = "source common.prf\ninclude? maybe.prf\n# a raw user comment\n"
        var written: String?
        _ = run(.sameFile,
                files: ["P.prf"],
                contents: ["P.prf": prof(log: true, logfile: "/old.log", extra: extra)],
                captured: { _, c in written = c })
        let out = try! XCTUnwrap(written)
        XCTAssertTrue(out.contains("source common.prf"), "directive preserved")
        XCTAssertTrue(out.contains("include? maybe.prf"), "optional-include directive preserved")
        XCTAssertTrue(out.contains("# a raw user comment"), "raw line preserved")
        XCTAssertTrue(out.contains("logfile = /shared/all.log"), "logfile updated")
    }
}
