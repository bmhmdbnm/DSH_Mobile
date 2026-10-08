import DSHKit
import XCTest

/// 本地历史存储（spec 007 T013/T014）：往返、幂等、窗口读回、7 天归档、预算淘汰、清理、旧 JSON 迁移。
final class TranscriptStoreTests: XCTestCase {

    private func record(_ seq: Int, filler: Int = 0) -> SessionRecord {
        let padding = filler > 0 ? String(repeating: "x", count: filler) : ""
        let json = #"{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"content":"\#(padding)"}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    /// A clock the test can move; `@unchecked Sendable` because the store reads
    /// it from its own actor while the test mutates it from the test task, and
    /// every access goes through the lock.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    private func makeStore(now: @escaping @Sendable () -> Date = Date.init,
                           budgetBytes: Int = TranscriptStore.budgetBytes,
                           maxAge: TimeInterval = TranscriptStore.maxAge) -> (TranscriptStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (TranscriptStore(root: root, now: now, budgetBytes: budgetBytes, maxAge: maxAge), root)
    }

    func testAppendThenReadWindowRoundTrips() async throws {
        let (store, _) = makeStore()
        try await store.append(scope: "mac", sessionId: "s1",
                               records: (1...100).map { record($0) }, hasMore: true)
        let page = try await store.loadWindow(scope: "mac", sessionId: "s1", before: 60, limit: 10)
        XCTAssertEqual(page.map(\.event.seq), Array(50...59), "最新的 10 条，且严格早于 before")
        let state = try await store.state(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.oldestSeq, 1)
        XCTAssertEqual(state?.newestSeq, 100)
        XCTAssertEqual(state?.hasMore, true)
    }

    func testAppendIsIdempotentAndKeepsTheNewestAnswer() async throws {
        let (store, _) = makeStore()
        let records = (1...20).map { record($0) }
        try await store.append(scope: "mac", sessionId: "s1", records: records, hasMore: true)
        try await store.append(scope: "mac", sessionId: "s1", records: records, hasMore: false)
        let page = try await store.loadWindow(scope: "mac", sessionId: "s1", before: 100, limit: 100)
        XCTAssertEqual(page.count, 20, "重放同一批记录不该产生副本")
        let state = try await store.state(scope: "mac", sessionId: "s1")
        XCTAssertEqual(state?.hasMore, false, "只有宿主说没有更早了才算到底")
    }

    func testSessionsAreIsolatedPerComputerAndPerSession() async throws {
        let (store, _) = makeStore()
        try await store.append(scope: "mac-a", sessionId: "s1", records: [record(5)], hasMore: true)
        let mine = try await store.loadWindow(scope: "mac-a", sessionId: "s1", before: 10, limit: 10)
        let otherComputer = try await store.loadWindow(scope: "mac-b", sessionId: "s1", before: 10, limit: 10)
        let otherSession = try await store.loadWindow(scope: "mac-a", sessionId: "s2", before: 10, limit: 10)
        XCTAssertEqual(mine.count, 1)
        XCTAssertTrue(otherComputer.isEmpty)
        XCTAssertTrue(otherSession.isEmpty)
    }

    func testLoadAroundReturnsBothSidesOfAHit() async throws {
        let (store, _) = makeStore()
        try await store.append(scope: "mac", sessionId: "s1", records: (1...50).map { record($0) }, hasMore: true)
        let window = try await store.loadAround(scope: "mac", sessionId: "s1", seq: 25, before: 3, after: 2)
        XCTAssertEqual(window.map(\.event.seq), [22, 23, 24, 25, 26, 27])
    }

    func testSevenDayArchiveBoundary() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (store, _) = makeStore(now: { clock.now })
        try await store.append(scope: "mac", sessionId: "old", records: [record(1)],
                               hasMore: true, openedAt: clock.now)
        let almost = try await { () async throws -> Int in
            clock.now = clock.now.addingTimeInterval(TranscriptStore.maxAge - 60)
            return try await store.evictExpired()
        }()
        XCTAssertEqual(almost, 0, "差一分钟还不算过期")
        clock.now = clock.now.addingTimeInterval(120)
        let expired = try await store.evictExpired()
        XCTAssertEqual(expired, 1, "超过 7 天即归档")
        let archived = try await store.loadWindow(scope: "mac", sessionId: "old", before: 10, limit: 10)
        XCTAssertTrue(archived.isEmpty)
        let oldState = try await store.state(scope: "mac", sessionId: "old")
        XCTAssertNil(oldState)
    }

    func testBudgetDropsTheLeastRecentlyOpenedSessionFirst() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let (store, _) = makeStore(now: { clock.now }, budgetBytes: 12_000)
        for (index, session) in ["ancient", "middle", "fresh"].enumerated() {
            let opened = clock.now.addingTimeInterval(Double(index) * 3600)
            try await store.append(scope: "mac", sessionId: session,
                                   records: (1...20).map { record($0, filler: 400) },
                                   hasMore: true, openedAt: opened)
        }
        let removed = try await store.enforceBudget()
        XCTAssertGreaterThan(removed, 0, "超预算就该淘汰")
        let ancientState = try await store.state(scope: "mac", sessionId: "ancient")
        let freshState = try await store.state(scope: "mac", sessionId: "fresh")
        XCTAssertNil(ancientState, "最久没打开的会话先走")
        XCTAssertNotNil(freshState)
    }

    func testSizeOnDiskCountsWalAndClearAllRemovesEverything() async throws {
        let (store, base) = makeStore()
        let root = base.appendingPathComponent("transcripts", isDirectory: true)
        try await store.append(scope: "mac", sessionId: "s1",
                               records: (1...200).map { record($0, filler: 200) }, hasMore: true)
        let before = await store.sizeOnDisk()
        XCTAssertGreaterThan(before, 0)
        try await store.clearAll()
        let after = await store.sizeOnDisk()
        XCTAssertEqual(after, 0, "清缓存要连库与 WAL 一起删")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testClearingOneSessionKeepsTheOthers() async throws {
        let (store, _) = makeStore()
        try await store.append(scope: "mac", sessionId: "keep", records: [record(1)], hasMore: true)
        try await store.append(scope: "mac", sessionId: "drop", records: [record(1)], hasMore: true)
        try await store.clear(scope: "mac", sessionId: "drop")
        let dropped = try await store.state(scope: "mac", sessionId: "drop")
        let kept = try await store.state(scope: "mac", sessionId: "keep")
        XCTAssertNil(dropped)
        XCTAssertNotNil(kept)
    }

    func testLegacyJSONIsImportedOnceAndRemoved() async throws {
        let (store, base) = makeStore()
        let directory = base.appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent(TranscriptStore.slug("mac"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let tail = SessionTranscriptSnapshot(
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            records: (1...5).map { record($0) }, oldestSeq: 1, throughSeq: 5, hasOlder: true
        )
        let older = SessionOlderSnapshot(
            savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            records: (6...10).map { record($0) }, oldestSeq: 6, hasOlder: true
        )
        try encoder.encode(tail).write(to: directory.appendingPathComponent("s1.json"))
        try encoder.encode(older).write(to: directory.appendingPathComponent("s1.older.json"))

        let imported = try await store.loadWindow(scope: "mac", sessionId: "s1", before: 100, limit: 100)
        XCTAssertEqual(imported.map(\.event.seq), Array(1...10), "尾部与更早段合并，按 seq 去重")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("s1.json").path),
                       "导入后旧文件要删掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("s1.older.json").path))
        let again = try await store.loadWindow(scope: "mac", sessionId: "s1", before: 100, limit: 100)
        XCTAssertEqual(again.count, 10, "第二次打开不该重复导入")
    }

    func testConcurrentAppendsAllLand() async throws {
        let (store, _) = makeStore()
        let batches: [[SessionRecord]] = (0..<8).map { batch in
            (batch * 10 + 1...(batch + 1) * 10).map { record($0) }
        }
        await withTaskGroup(of: Void.self) { group in
            for records in batches {
                group.addTask {
                    try? await store.append(scope: "mac", sessionId: "s1", records: records, hasMore: true)
                }
            }
        }
        let all = try await store.loadWindow(scope: "mac", sessionId: "s1", before: 1000, limit: 1000)
        XCTAssertEqual(all.count, 80, "并发写入不该丢记录")
    }
}
