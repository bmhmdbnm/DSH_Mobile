import DSHKit
import Foundation
import XCTest

/// 008 里"能离线验"的那一半：行载荷的回收/预算、身份的稳定与排序。
/// （宿主本身的原子位移与"不再崩"必须在仿真器里验，见 008 的 Phase 0 spike。）
final class TranscriptRowPayloadTests: XCTestCase {

    private func record(seq: Int, text: String) -> SessionRecord {
        let json = """
        {"type":"user/message","seq":\(seq),"time":1789276358732,
         "data":{"content":[{"type":"text","text":"\(text)"}],
                 "source":{"kind":"user","rpcId":"r\(seq)"},"role":"user","id":"m\(seq)"}}
        """
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    private func items(_ pairs: [(Int, String)]) -> [TimelineItem] {
        var timeline = ChatTimeline()
        timeline.reset(with: pairs.map { record(seq: $0.0, text: $0.1) })
        return timeline.items
    }

    func testReclaimKeepsIdentitySeqAndHeight() {
        let row = items([(100, "hello world")])[0]
        var payload = TranscriptRowPayload(item: row, height: 42)
        XCTAssertEqual(payload.id, row.id)
        XCTAssertFalse(payload.isReclaimed)
        XCTAssertEqual(payload.payloadBytes, "hello world".utf8.count)

        payload.reclaim()
        XCTAssertTrue(payload.isReclaimed)
        XCTAssertEqual(payload.id, row.id, "回收不许换身份")
        XCTAssertEqual(payload.height, 42, "高度缓存要留着，否则水合时会跳")
        XCTAssertEqual(payload.payloadBytes, 0, "回收之后不再计入预算")
        guard case .reclaimed(let seq, _, _) = payload.state else { return XCTFail("状态不对") }
        XCTAssertEqual(seq, 100, "要记住 seq 才能从本地库取回")
    }

    func testRehydrateOnlyBumpsContentVersion() {
        let rows = items([(1, "a"), (2, "b")])
        var payload = TranscriptRowPayload(item: rows[0], height: 10)
        payload.reclaim()
        let version = payload.contentVersion
        payload.rehydrate(with: rows[0])
        XCTAssertFalse(payload.isReclaimed)
        XCTAssertEqual(payload.id, rows[0].id)
        XCTAssertEqual(payload.contentVersion, version + 1, "内容版本要变，高度缓存的键才失效")
        XCTAssertEqual(payload.height, 10, "高度本身不改")
    }

    func testBudgetReclaimsFarthestFirstUntilInsideTheLimit() {
        let rows = items((1...6).map { ($0, String(repeating: "x", count: 100)) })
        let payloads = rows.map { TranscriptRowPayload(item: $0, height: 20) }
        // 六条各 100 字节（共 600），预算 200 ⇒ 必须收掉 4 条；视口在第 3 条上。
        let budget = TranscriptPayloadBudget(limitBytes: 200)
        let picked = budget.rowsToReclaim(payloads, visible: 2..<3, keepDistance: 0)
        XCTAssertEqual(picked, [payloads[0].id, payloads[5].id, payloads[1].id, payloads[4].id],
                       "从两端（离视口最远）往外收，交替取")
        XCTAssertFalse(picked.contains(payloads[2].id), "视口里的行不许动")
        let kept = payloads.filter { !picked.contains($0.id) }.reduce(0) { $0 + $1.payloadBytes }
        XCTAssertLessThanOrEqual(kept, 200, "收完之后要回到预算内")
    }

    func testBudgetKeepsProtectedBandAndDoesNothingUnderLimit() {
        let rows = items((1...4).map { ($0, String(repeating: "y", count: 50)) })
        let payloads = rows.map { TranscriptRowPayload(item: $0, height: 10) }
        XCTAssertTrue(TranscriptPayloadBudget(limitBytes: 10_000)
            .rowsToReclaim(payloads, visible: 0..<4, keepDistance: 0).isEmpty, "没超预算就不动")
        // 四条各 50 字节（共 200），预算 60 ⇒ 超 140；但视口在第 2 条、视口外保留 1 条
        // ⇒ 前三条都在保护带里，只有第 4 条能动——所以**宁可暂时超预算，也不动视口附近的行**。
        let picked = TranscriptPayloadBudget(limitBytes: 60)
            .rowsToReclaim(payloads, visible: 1..<2, keepDistance: 1)
        XCTAssertEqual(picked, [payloads[3].id], "保护带里的行不许为了预算被动")
    }

    func testIdentityAndOrderingAreStable() {
        let rows = items([(10, "a"), (30, "c"), (20, "b")])
        let ordered = TranscriptListSection.ordered(rows)
        XCTAssertEqual(ordered.map(\.seq), [10, 20, 30])
        XCTAssertEqual(Set(ordered.map { TranscriptListSection.identifier(for: $0) }).count, 3)
        // 同一批行的标识在两次调用之间不变（跳转/高亮都依赖这一点）
        XCTAssertEqual(TranscriptListSection.identifier(for: ordered[0]),
                       TranscriptListSection.identifier(for: rows.first { $0.seq == 10 }!))
    }

    func testIsPrependDistinguishesOlderPages() {
        let current = items([(100, "a"), (200, "b")])
        let older = items([(50, "old")])
        let newer = items([(300, "new")])
        XCTAssertTrue(TranscriptListSection.isPrepend(older, current: current))
        XCTAssertFalse(TranscriptListSection.isPrepend(newer, current: current))
    }
}
