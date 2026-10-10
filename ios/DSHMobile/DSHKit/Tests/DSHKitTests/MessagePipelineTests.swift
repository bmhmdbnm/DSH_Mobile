@testable import DSHKit
import XCTest

/// MessagePipeline（contracts/memory-pipeline.md / tasks T009）：
/// 快照流的首帧 + 增量广播、多订阅者独立、gap 生灭并入 diff、
/// 发送五拍（pending → 落库 → 网络 → 确认原地替换，身份不变）。
final class MessagePipelineTests: XCTestCase {

    private enum TestError: Error { case sendFailed }

    private var directory: URL!
    private var store: MessageStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("message-pipeline-tests-\(UUID().uuidString)")
        store = try MessageStore(path: directory.appendingPathComponent("test.sqlite3"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let session = MessagePipeline.SessionRef(scope: "mac", sessionId: "s1")

    private func record(_ seq: Int, type: String = "assistant/message",
                        text: String = "hello") -> SessionRecord {
        let json = #"{"type":"\#(type)","seq":\#(seq),"time":1789276358732,"data":{"text":"\#(text)"}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    /// 空取页器（这些用例不走网络水合，只测聚合与上行）。
    private func makePipeline(
        sender: @escaping MessagePipeline.Sender = { ref, text, _ in
            let json = #"{"type":"user/message","seq":42,"time":1789276358733,"data":{"text":"\#(text)"}}"#
            return SessionRecord(event: try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8)))
        }
    ) -> MessagePipeline {
        MessagePipeline(
            store: store,
            fetchFactory: { _ in { _ in
                SessionPipeline.FetchPage(records: [], hasMore: false, clamped: false)
            } },
            sender: sender,
            now: { 1000 })
    }

    // MARK: - 订阅与广播

    func testInitialSnapshotCarriesPrimedRowsThenDiffs() async throws {
        let pipeline = makePipeline()
        // 订阅前已有水合数据：首帧必须带上（不能丢）。
        let sessionPipeline = await pipeline.pipeline(for: session)
        await sessionPipeline.apply(event: record(1).event)
        await sessionPipeline.apply(event: record(2).event)

        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        guard case .insert(let rows)? = initial?.changes.first else {
            return XCTFail("首帧应是全量 insert，实收 \(String(describing: initial))")
        }
        XCTAssertEqual(rows.map(\.id).count, 2)

        // 之后只发增量。
        await sessionPipeline.apply(event: record(3).event)
        let delta = await iterator.next()
        guard case .insert(let inserted)? = delta?.changes.first else {
            return XCTFail("增量应是 insert，实收 \(String(describing: delta))")
        }
        XCTAssertEqual(inserted.count, 1)
        if case .message(let message) = inserted[0] {
            XCTAssertEqual(message.seq, 3)
        } else {
            XCTFail("应是数据行")
        }
    }

    func testMultipleSubscribersEachGetOwnStream() async throws {
        let pipeline = makePipeline()
        let sessionPipeline = await pipeline.pipeline(for: session)

        let streamA = await pipeline.snapshots(for: session)
        await sessionPipeline.apply(event: record(7).event)
        try await Task.sleep(nanoseconds: 100_000_000) // 泵落定：seq=7 进聚合状态
        // B 订阅得晚：它的首帧也要含 seq=7（各自独立快照）。
        let streamB = await pipeline.snapshots(for: session)

        var iteratorA = streamA.makeAsyncIterator()
        var iteratorB = streamB.makeAsyncIterator()

        let initialB = await iteratorB.next()
        guard case .insert(let rowsB)? = initialB?.changes.first else {
            return XCTFail("B 首帧应是全量 insert")
        }
        XCTAssertEqual(rowsB.count, 1)

        // 新事件：A、B 都收到增量（A 先收过 seq=7 的 delta，这里读到 8 为止）。
        await sessionPipeline.apply(event: record(8).event)
        var sawDeltaA = false
        for _ in 0..<3 {
            guard let diff = await iteratorA.next() else { break }
            if case .insert(let rows) = diff.changes.first, rows.count == 1 {
                sawDeltaA = true
                break
            }
        }
        XCTAssertTrue(sawDeltaA)
        let deltaB = await iteratorB.next()
        XCTAssertNotNil(deltaB)
    }

    func testGapRowsAppearInInitialSnapshotAndDieInDiff() async throws {
        // gap 行生灭走 SessionPipeline 的 fetch 合并路径，这里用脚本化取页器。
        let stub = FetchScript()
        let pipeline = MessagePipeline(
            store: store,
            fetchFactory: { _ in { range in try await stub.fetch(range) } },
            sender: { _, _, _ in throw TestError.sendFailed },
            now: { 1000 })
        let sessionPipeline = await pipeline.pipeline(for: session)
        // 下行事件预置两段窗口（不经 records()，避免预取提前填洞造成竞态）。
        for seq in 1...50 { await sessionPipeline.apply(event: record(seq).event) }
        for seq in 101...150 { await sessionPipeline.apply(event: record(seq).event) }

        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        let gapIDs = initial?.changes.flatMap { change -> [String] in
            if case .insert(let rows) = change {
                return rows.compactMap { row in
                    if case .gap(let gap) = row { return gap.id }
                    return nil
                }
            }
            return []
        } ?? []
        XCTAssertEqual(gapIDs, ["gap:51-100"])

        // 补齐后：同一 diff 里 gap 行被 remove。
        await stub.set(51...100, records: (51...100).map { record($0) }, hasMore: true)
        _ = try await sessionPipeline.records(in: 55...60)
        var sawGapRemoved = false
        while let diff = await iterator.next() {
            for change in diff.changes {
                if case .remove(let ids) = change, ids.contains("gap:51-100") {
                    sawGapRemoved = true
                }
            }
            if sawGapRemoved { break }
        }
        XCTAssertTrue(sawGapRemoved)
    }

    // MARK: - 上行发送

    func testSendPendingThenConfirmKeepsIdentity() async throws {
        let pipeline = makePipeline()
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // 首帧（空）

        let clientId = try await pipeline.send(text: "你好", to: session)

        // ① 乐观插入：pending，身份 = clientId。
        let insertDiff = await iterator.next()
        guard case .insert(let rows)? = insertDiff?.changes.first,
              case .message(let pending) = rows.first else {
            return XCTFail("应有 pending 插入，实收 \(String(describing: insertDiff))")
        }
        XCTAssertEqual(pending.id, clientId)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(pending.record.event.data["text"]?.stringValue, "你好")

        // ② 确认：原地替换（身份不变），seq 换成服务端 42，状态 sent。
        let updateDiff = await iterator.next()
        guard case .update(let updated)? = updateDiff?.changes.first,
              case .message(let confirmed) = updated.first else {
            return XCTFail("应有确认 update，实收 \(String(describing: updateDiff))")
        }
        XCTAssertEqual(confirmed.id, clientId) // 身份不变
        XCTAssertEqual(confirmed.seq, 42)
        XCTAssertEqual(confirmed.status, .sent)
    }

    func testSendFailureMarksRowFailedWithSameIdentity() async throws {
        let pipeline = makePipeline { _, _, _ in throw TestError.sendFailed }
        let stream = await pipeline.snapshots(for: session)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        _ = try? await pipeline.send(text: "hi", to: session)
        // pending insert 与失败 update 的身份必须一致（失败不重建行）。
        let insertDiff = await iterator.next()
        guard case .insert(let inserted)? = insertDiff?.changes.first,
              case .message(let pending) = inserted.first else {
            return XCTFail("应有 pending 插入，实收 \(String(describing: insertDiff))")
        }
        let updateDiff = await iterator.next()
        guard case .update(let rows)? = updateDiff?.changes.first,
              case .message(let failed) = rows.first else {
            return XCTFail("应有失败 update，实收 \(String(describing: updateDiff))")
        }
        XCTAssertEqual(failed.id, pending.id)
        XCTAssertEqual(failed.status, .failed)
    }

    func testSendPersistsPendingThenConfirmThroughWriteQueue() async throws {
        let pipeline = makePipeline()
        _ = try await pipeline.send(text: "落库", to: session)
        let sessionPipeline = await pipeline.pipeline(for: session)
        await sessionPipeline.flushPendingWrites()
        try await Task.sleep(nanoseconds: 200_000_000) // 落库是异步批量写
        // confirmPending 落库后：正式记录可读，pending 行已被替换。
        let records = try await store.records(scope: "mac", sessionId: "s1", in: 1...50)
        XCTAssertEqual(records.map(\.event.seq), [42])
        XCTAssertEqual(records.first?.event.data["text"]?.stringValue, "落库") // sender 回包带回原文
    }

    // MARK: - 假件

    /// 对齐页脚本化取页器（本文件自用，行为同 SessionPipelineTests 的 stub）。
    private actor FetchScript {
        private var pages: [Int: SessionPipeline.FetchPage] = [:]

        func set(_ range: ClosedRange<Int>, records: [SessionRecord], hasMore: Bool) {
            pages[range.lowerBound] = SessionPipeline.FetchPage(records: records, hasMore: hasMore)
        }

        func fetch(_ range: ClosedRange<Int>) throws -> SessionPipeline.FetchPage {
            pages[range.lowerBound] ?? SessionPipeline.FetchPage(records: [], hasMore: true)
        }
    }
}
