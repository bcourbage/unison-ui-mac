import XCTest
@testable import unison_ui_mac

/// Session-scoped CLI options against the ACTUAL rebuilt engine through the
/// production bridge (`unison_bridge_set_session_args` + `unison_bridge_init1`
/// + `unison_bridge_init2`). The observable is real scan scope, not a model.
///
/// Proves, end to end:
///  - `-path` (a CUSTOM-typed pref) applied by the session actually scopes the
///    scan, and a new session with no overrides inherits none of it;
///  - the overrides survive a reconnect (init1 re-run) without broadening or
///    accumulating;
///  - a valid override followed by an invalid one fails BEFORE any connect/scan
///    (the fatal path fires, init1-complete never does), and the next session's
///    preferences are clean.
///
/// Ordering: the class name sorts after `BridgeTests`, whose `test_c…` consumes
/// the process-global one-shot `firstTime` init1 (upstream parses `Sys.argv`
/// only on the first profile load). Handlers and stored session args are
/// process-global; `tearDown` restores benign handlers and clears the args so a
/// later suite's init1 cannot inherit a stale scope.
final class SessionArgsBridgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // A real do_unisonInit1 raise routes to the app's fatal path, which shows
        // a blocking modal. Suppress it so the hosted runloop isn't wedged; the
        // engine→fatal delivery is still exercised (see test_c).
        UnisonBridge.testFatalModalSuppressed = true
    }

    override func tearDown() {
        UnisonBridge.setSessionArgs([])
        UnisonBridge.installInit1CompleteHandler { _ in }
        UnisonBridge.installInit2CompleteHandler { _ in }
        UnisonBridge.installFatalHandler { _, _ in }
        UnisonBridge.testFatalModalSuppressed = false
        super.tearDown()
    }

    /// A local fixture with a top-level differing file AND a `sub/` subtree that
    /// differs on each side, so `-path sub` is observably narrower than a full
    /// scan (the top-level row disappears).
    private func makeScopedFixture(_ name: String) throws -> IntegrationFixture {
        let f = try IntegrationFixture(name: name)
        let fm = FileManager.default
        try fm.createDirectory(at: f.aRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.bRoot.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "topA\n".write(to: f.aRoot.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "subA\n".write(to: f.aRoot.appendingPathComponent("sub/only-a.txt"), atomically: true, encoding: .utf8)
        try "subB\n".write(to: f.bRoot.appendingPathComponent("sub/only-b.txt"), atomically: true, encoding: .utf8)
        return f
    }

    /// Set the session's args (the driver's contract: always before init1), then
    /// drive init1 → init2 and return the scanned rows.
    private func scan(_ f: IntegrationFixture, args: [String]) -> [StateItem] {
        let done = expectation(description: "init2 complete (args=\(args))")
        var captured: [StateItem] = []
        UnisonBridge.installInit1CompleteHandler { needsPrompt in
            XCTAssertFalse(needsPrompt, "local-only fixture should never prompt")
            _ = unison_bridge_init2()
        }
        UnisonBridge.installInit2CompleteHandler { items in captured = items; done.fulfill() }
        XCTAssertEqual(UnisonBridge.setSessionArgs(args), UNISON_BRIDGE_OK,
                       "set_session_args must be registered in the rebuilt blob")
        f.profileName.withCString { _ = unison_bridge_init1($0) }
        wait(for: [done], timeout: 20)
        return captured
    }

    /// Drive init1 TWICE (each preceded by set_session_args, as the driver does
    /// on a reconnect), then scan once. Models a reconnect that re-runs init1.
    private func scanAfterReconnect(_ f: IntegrationFixture, args: [String]) -> [StateItem] {
        for pass in 1...2 {
            let c = expectation(description: "init1 complete pass \(pass)")
            UnisonBridge.installInit1CompleteHandler { _ in c.fulfill() }
            XCTAssertEqual(UnisonBridge.setSessionArgs(args), UNISON_BRIDGE_OK)
            f.profileName.withCString { _ = unison_bridge_init1($0) }
            wait(for: [c], timeout: 20)
        }
        let done = expectation(description: "init2 after reconnect")
        var captured: [StateItem] = []
        UnisonBridge.installInit2CompleteHandler { items in captured = items; done.fulfill() }
        _ = unison_bridge_init2()
        wait(for: [done], timeout: 20)
        return captured
    }

    func test_a_pathScopesScan_andNewSessionInheritsNone() throws {
        let f = try makeScopedFixture("scope")

        let scoped = Set(scan(f, args: ["-path", "sub"]).map(\.path))
        XCTAssertFalse(scoped.contains("top.txt"),
                       "-path sub must exclude the top-level file (CUSTOM pref applied)")
        XCTAssertTrue(scoped.contains { $0.hasSuffix("only-a.txt") },
                      "the in-scope left file is reported")
        XCTAssertTrue(scoped.contains { $0.hasSuffix("only-b.txt") },
                      "the in-scope right file is reported")

        // A new session with no overrides must inherit none of the previous
        // scope — the top-level file reappears.
        let full = Set(scan(f, args: []).map(\.path))
        XCTAssertTrue(full.contains("top.txt"),
                      "a fresh session with no overrides scans the whole tree")
    }

    func test_b_reconnectReappliesScope_withoutAccumulating() throws {
        let f = try makeScopedFixture("reconnect")
        let single = Set(scan(f, args: ["-path", "sub"]).map(\.path))
        let doubled = scanAfterReconnect(f, args: ["-path", "sub"])
        let doubledSet = Set(doubled.map(\.path))

        XCTAssertEqual(doubledSet, single,
                       "a reconnect re-applies the same scope — identical rows, not broadened")
        XCTAssertEqual(doubled.count, single.count,
                       "no accumulation/duplication of the path list across the reconnect")
        XCTAssertFalse(doubledSet.contains("top.txt"),
                       "the scope did not leak to a full scan after the reconnect")
    }

    func test_c_invalidOverride_failsBeforeConnect_thenRecoversClean() throws {
        let f = try makeScopedFixture("failiso")

        let fatal = expectation(description: "fatal fired for the invalid override")
        var fatalMessage = ""
        var init1CompleteFired = false
        UnisonBridge.installInit1CompleteHandler { _ in init1CompleteFired = true }  // must NOT fire
        UnisonBridge.installInit2CompleteHandler { _ in
            XCTFail("no scan may start after a failed override")
        }
        UnisonBridge.installFatalHandler { msg, _ in fatalMessage = msg; fatal.fulfill() }

        // Observe the actual connection-setup boundary: this counter advances only
        // when do_unisonInit1 reaches root validation + openConnectionStart, which
        // is strictly AFTER session arguments are applied. A failed apply must
        // leave it unchanged — proving no connection or scan started, not merely
        // that init1 "did not complete".
        let setupBefore = unison_bridge_test_connect_setup_count()
        XCTAssertGreaterThanOrEqual(setupBefore, 0,
                       "connect-setup counter must be available (rebuilt blob with patch 0008)")

        // A valid override (-path sub) followed by an invalid one (-maxerrors
        // notanint). The parser applies -path, then raises on the bad int —
        // before root validation and openConnectionStart.
        XCTAssertEqual(UnisonBridge.setSessionArgs(["-path", "sub", "-maxerrors", "notanint"]),
                       UNISON_BRIDGE_OK)
        f.profileName.withCString { _ = unison_bridge_init1($0) }
        wait(for: [fatal], timeout: 20)

        XCTAssertEqual(unison_bridge_test_connect_setup_count(), setupBefore,
                       "a failed argument apply must reach NO connection/scan setup")
        XCTAssertFalse(init1CompleteFired,
                       "the connect never completed → no connection or scan began")
        let m = fatalMessage.lowercased()
        XCTAssertTrue(m.contains("maxerrors") || m.contains("notanint") || m.contains("integer"),
                      "the fatal names the offending option, got: \(fatalMessage)")

        // Recovery must be demonstrably clean: a following session with no
        // overrides scans normally, so no partial state (-path sub, or a broken
        // maxerrors) leaked past the failure.
        let clean = Set(scan(f, args: []).map(\.path))
        XCTAssertTrue(clean.contains("top.txt"),
                      "the next session's preferences are clean (full scope restored)")
        XCTAssertTrue(clean.contains { $0.hasSuffix("only-a.txt") })
        // The clean load DID reach connection setup — so the unchanged count
        // above genuinely reflects the failed load stopping early, not a dead
        // counter.
        XCTAssertGreaterThan(unison_bridge_test_connect_setup_count(), setupBefore,
                       "a normal load advances the connect-setup counter")
    }

    /// Marshal a vector through the SAME out-marshaling as the session-args
    /// accessor (the C helper), returning its status + copied args.
    private func marshal(_ argv: [String]) -> (status: Int32, args: [String]) {
        let cargv: [UnsafePointer<CChar>?] = argv.map { UnsafePointer(strdup($0)) }
        defer { for p in cargv { free(UnsafeMutablePointer(mutating: p)) } }
        var outArgc: Int32 = 0
        var outArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        let st = cargv.withUnsafeBufferPointer {
            unison_bridge_test_marshal_string_array(Int32(argv.count), $0.baseAddress, &outArgc, &outArgv)
        }
        var out: [String] = []
        if st == UNISON_BRIDGE_OK, let base = outArgv {
            for i in 0..<Int(outArgc) { if let s = base[i] { out.append(String(cString: s)); free(s) } }
        }
        if let base = outArgv { free(base) }
        return (st, out)
    }

    /// **Finding P2 (allocation failure).** A failed element copy must return
    /// non-OK with EMPTY outputs — never a partially-copied vector that silently
    /// drops a token (which would change the remaining tokens' meaning).
    func test_d_marshalStringArray_allocFailureIsEmptyNotPartial() {
        let ok = marshal(["-path", "A", "-path", "B"])
        XCTAssertEqual(ok.status, UNISON_BRIDGE_OK)
        XCTAssertEqual(ok.args, ["-path", "A", "-path", "B"])

        // Fail the 1st copy → non-OK, empty (no dropped token).
        unison_bridge_test_fail_strdup_at(1)
        let f1 = marshal(["-path", "A", "-path", "B"])
        XCTAssertNotEqual(f1.status, UNISON_BRIDGE_OK)
        XCTAssertEqual(f1.args, [], "a failed copy returns empty, not a partial vector")

        // Fail the 2nd copy → non-OK, empty (the first is freed, not leaked/returned).
        unison_bridge_test_fail_strdup_at(2)
        let f2 = marshal(["-path", "A", "-path", "B"])
        XCTAssertNotEqual(f2.status, UNISON_BRIDGE_OK)
        XCTAssertEqual(f2.args, [])

        // Runtime still usable after the injected failures.
        unison_bridge_test_fail_strdup_at(0)
        let ok2 = marshal(["-x"])
        XCTAssertEqual(ok2.status, UNISON_BRIDGE_OK)
        XCTAssertEqual(ok2.args, ["-x"])
    }
}
