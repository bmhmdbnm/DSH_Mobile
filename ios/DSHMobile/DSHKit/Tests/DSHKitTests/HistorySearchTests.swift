import DSHKit
import XCTest

/// P2 的线格式与"命中落在哪一行"（spec 007 T036）。
final class HistorySearchTests: XCTestCase {

    private func userMessage(seq: Int, text: String = "hi") -> SessionRecord {
        let json = """
        {"type":"user/message","seq":\(seq),"time":1789276358732,
         "data":{"content":[{"type":"text","text":"\(text)"}],
                 "source":{"kind":"user","rpcId":"r\(seq)"},"role":"user","id":"m\(seq)"}}
        """
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    func testRequestEncodesFlatArgsAndOmitsWhatIsNotSet() throws {
        let request = HistorySearchRequest(address: .session(sessionId: "s1"), query: "needle")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "query"], "没给的可选字段不该出现")
        XCTAssertNil(object["request"], "连接器本地方法不吃 {request: …} 信封")
    }

    func testResponseDecodesHitsWithHighlightOffsets() throws {
        let json = """
        {"hits":[{"seq":1685,"role":"me","snippet":"…关于渐变背景图的提问…","highlightStart":4,"highlightLength":5}],
         "cursor":"1600","hasMore":true,"source":"scan"}
        """
        let value = try JSONDecoder().decode(HistorySearchValue.self, from: Data(json.utf8))
        XCTAssertEqual(value.hits.first?.seq, 1685)
        XCTAssertEqual(value.hits.first?.role, "me")
        XCTAssertEqual(value.cursor, "1600")
        XCTAssertTrue(value.hasMore)
        XCTAssertEqual(value.source, "scan")
    }

    func testAHitLandsOnTheRowThatOwnsItsSeq() {
        let items = ChatTimeline()
        var timeline = items
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200), userMessage(seq: 300)])
        let rows = timeline.items
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 250, in: rows)?.seq, 200, "落在 200 那一行")
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 200, in: rows)?.seq, 200, "正好等于行自己的 seq")
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 999, in: rows)?.seq, 300, "比最后一行还新：最后一行")
        XCTAssertEqual(TranscriptHitLocator.row(forSeq: 1, in: rows)?.seq, 100, "比第一行还旧：第一行")
        XCTAssertNil(TranscriptHitLocator.row(forSeq: 1, in: []))
    }

    func testAttachFillsRowIDsAndDropsHitsWithNoRow() {
        var timeline = ChatTimeline()
        timeline.reset(with: [userMessage(seq: 100), userMessage(seq: 200)])
        let hits = [
            HistorySearchHit(seq: 200, role: "me", snippet: "a needle", highlightStart: 2, highlightLength: 6),
            HistorySearchHit(seq: 150, role: "agent", snippet: "b needle", highlightStart: 2, highlightLength: 6),
        ]
        let mapped = TranscriptHitLocator.attach(hits: hits, to: timeline.items)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[0].role, .me)
        XCTAssertEqual(mapped[1].role, .agent)
        XCTAssertEqual(mapped[0].id, timeline.items.last?.id, "200 那一行")
        XCTAssertEqual(mapped[1].seq, 150, "命中自己的 seq 保留（跳转与高亮都用它）")
    }
}
