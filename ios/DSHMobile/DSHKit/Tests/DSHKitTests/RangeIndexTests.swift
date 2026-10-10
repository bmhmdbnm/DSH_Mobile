import DSHKit
import XCTest

/// 有效连续区间集（spec 009 §6 / tasks T003）：插入合并、相邻并段、
/// 嵌套吸收、空洞保留、二分判定三分支、缺口推导。
final class RangeIndexTests: XCTestCase {

    func testInsertIntoEmptyMakesOneSpan() {
        var index = RangeIndex()
        index.insert(10...20)
        XCTAssertEqual(index.spans, [.init(10, 20)])
        XCTAssertEqual(index.coveredCount, 11)
    }

    func testOverlappingInsertsMergeIntoOneSpan() {
        var index = RangeIndex()
        index.insert(10...20)
        index.insert(15...30)
        index.insert(5...12)
        XCTAssertEqual(index.spans, [.init(5, 30)])
    }

    /// 端点差 1（10...20 与 21...25）视为连续，必须并段——否则翻页拼接处会
    /// 被误判成缺口（spec §6 相邻即合并）。
    func testAdjacentSpansMerge() {
        var index = RangeIndex()
        index.insert(10...20)
        index.insert(21...25)
        XCTAssertEqual(index.spans, [.init(10, 25)])
    }

    func testDisjointSpansStaySeparateAndSorted() {
        var index = RangeIndex()
        index.insert(100...200)
        index.insert(10...20)
        index.insert(50...60)
        XCTAssertEqual(index.spans, [.init(10, 20), .init(50, 60), .init(100, 200)])
    }

    /// 新段把两个旧段之间的空洞填上时，三段并成一段（跳转后往回翻拉通）。
    func testBridgeInsertMergesBothSides() {
        var index = RangeIndex()
        index.insert(10...20)
        index.insert(50...60)
        index.insert(21...49)
        XCTAssertEqual(index.spans, [.init(10, 60)])
    }

    func testNestedInsertIsIdempotent() {
        var index = RangeIndex()
        index.insert(10...100)
        index.insert(40...50)
        index.insert(10...100)
        XCTAssertEqual(index.spans, [.init(10, 100)])
        XCTAssertEqual(index.coveredCount, 91)
    }

    func testCoverageFullHit() {
        let index = RangeIndex(spans: [.init(10, 100)])
        XCTAssertEqual(index.coverage(of: 40...60), .full)
    }

    func testCoveragePartialSplitsMissingOnBothSides() {
        let index = RangeIndex(spans: [.init(40, 60)])
        XCTAssertEqual(
            index.coverage(of: 30...70),
            .partial(covered: [.init(40, 60)], missing: [.init(30, 39), .init(61, 70)])
        )
    }

    func testCoverageNoneWhenDisjoint() {
        let index = RangeIndex(spans: [.init(10, 20)])
        XCTAssertEqual(index.coverage(of: 50...60), .none)
    }

    func testCoveragePartialAcrossMultipleSpans() {
        let index = RangeIndex(spans: [.init(10, 20), .init(40, 50), .init(80, 90)])
        XCTAssertEqual(
            index.coverage(of: 15...85),
            .partial(
                covered: [.init(15, 20), .init(40, 50), .init(80, 85)],
                missing: [.init(21, 39), .init(51, 79)]
            )
        )
    }

    func testContainsSeq() {
        let index = RangeIndex(spans: [.init(10, 20), .init(40, 50)])
        XCTAssertTrue(index.contains(10))
        XCTAssertTrue(index.contains(45))
        XCTAssertFalse(index.contains(21))
        XCTAssertFalse(index.contains(0))
    }

    /// 缺口行（spec「缺口行的生命周期」）：有数据但有空洞时给出中间缺口；
    /// 全命中与完全不命中都不产生缺口行。
    func testGapsWithinWindow() {
        let index = RangeIndex(spans: [.init(10, 20), .init(40, 50)])
        XCTAssertEqual(index.gaps(within: 10...50), [.init(21, 39)])
        XCTAssertEqual(index.gaps(within: 10...20), [])
        XCTAssertEqual(index.gaps(within: 100...200), [])
    }

    func testNewestAndOldest() {
        var index = RangeIndex()
        XCTAssertNil(index.newest)
        XCTAssertNil(index.oldest)
        index.insert(10...20)
        index.insert(40...50)
        XCTAssertEqual(index.newest, 50)
        XCTAssertEqual(index.oldest, 10)
    }
}
