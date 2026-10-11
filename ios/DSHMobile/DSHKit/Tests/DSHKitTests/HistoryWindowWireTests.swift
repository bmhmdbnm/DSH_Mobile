import DSHKit
import XCTest

/// 连接器窗口方法的线格式（spec 007 T004/T005）。
///
/// 这些断言防的是"客户端与连接器对参数形状的理解漂移"——连接器的本地方法收**扁平**参数
/// （`{address, before, …}`），宿主端点才用 `{request: …}` 信封；混用会得到一个
/// `gateway/arguments-invalid`，而那看起来像"取页失败"，正是我们要避免的误判。
final class HistoryWindowWireTests: XCTestCase {

    private func record(_ seq: Int) -> SessionRecord {
        let json = #"{"type":"user/message","seq":\#(seq),"time":1789276358732,"data":{"content":[]}}"#
        let event = try! JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        return SessionRecord(event: event)
    }

    func testRequestEncodesFlatArgs() throws {
        let request = HistoryWindowRequest(
            address: .session(sessionId: "s1"),
            before: 700, through: 800, limit: 60, maxBytes: 262_144
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "before", "through", "limit", "maxBytes"])
        XCTAssertNil(object["request"], "连接器本地方法不吃 {request: …} 信封")
        XCTAssertEqual(object["before"] as? Int, 700)
        let address = try XCTUnwrap(object["address"] as? [String: Any])
        XCTAssertEqual(address["sessionId"] as? String, "s1")
    }

    func testOptionalFieldsStayOptional() throws {
        let request = HistoryWindowRequest(
            address: .session(sessionId: "s1"), before: 10
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["address", "before"], "没给的可选字段不该出现")
    }

    func testResponseDecodesIntoAPagerPage() throws {
        let json = """
        {"records":[{"event":{"type":"user/message","seq":440,"time":1789276358732,"data":{}}},
                    {"event":{"type":"assistant/message","seq":441,"time":1789276358733,"data":{}}}],
         "startSeq":440,"endSeq":441,"hasMore":true,"truncatedBy":"count","clamped":false}
        """
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(json.utf8))
        let page = value.page()
        XCTAssertEqual(page.startSeq, 440)
        XCTAssertEqual(page.endSeq, 441)
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.clamped)
        XCTAssertEqual(page.records.map(\.event.seq), [440, 441])
    }

    func testClampedFlagSurvivesTheWire() throws {
        let json = """
        {"records":[{"event":{"type":"user/message","seq":1,"time":1,"data":{}}}],
         "startSeq":1,"endSeq":1,"hasMore":false,"clamped":true}
        """
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(json.utf8))
        XCTAssertTrue(value.page().clamped, "裁剪过的日志要靠这个标志与'缺口'区分")
    }

    func testRecordsWithoutSeqBoundsFallBackToTheirOwnRange() throws {
        let json = """
        {"records":[{"event":{"type":"user/message","seq":5,"time":1,"data":{}}}],
         "startSeq":null,"endSeq":null,"hasMore":false}
        """
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(json.utf8))
        XCTAssertEqual(value.page().startSeq, 5)
        XCTAssertEqual(value.page().endSeq, 5)
    }

    /// T039：`scanBoundary` 是可选字段——新连接器给（空页也前进的扫描边界），
    /// 老连接器不给就解码成 nil，回填退回旧口径（最老返回记录）。
    func testScanBoundaryIsOptionalOnTheWire() throws {
        let withBoundary = """
        {"records":[],"startSeq":null,"endSeq":null,"hasMore":true,"scanBoundary":388}
        """
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(withBoundary.utf8))
        XCTAssertEqual(value.scanBoundary, 388)
        XCTAssertTrue(value.records.isEmpty)
        let withoutBoundary = """
        {"records":[],"startSeq":null,"endSeq":null,"hasMore":true}
        """
        let old = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(withoutBoundary.utf8))
        XCTAssertNil(old.scanBoundary, "老连接器没有这个字段，读出来必须是 nil 而不是 0")
    }
}
