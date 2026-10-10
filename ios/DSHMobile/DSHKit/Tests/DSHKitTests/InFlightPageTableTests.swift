import DSHKit
import XCTest

/// in-flight 页表（spec 009「支撑机制」/ tasks T006）：
/// 同页合并、代数防回包错位、取消、优先级升级与抢占。
final class InFlightPageTableTests: XCTestCase {

    private typealias Table = InFlightPageTable<String>

    func testFirstBeginStartsRequest() {
        var table = Table()
        XCTAssertEqual(table.begin("p1", priority: .prefetch), .start(generation: 1))
        XCTAssertTrue(table.isInFlight("p1"))
    }

    func testDuplicateBeginJoinsWithoutNewRequest() {
        var table = Table()
        let first = table.begin("p1", priority: .prefetch)
        XCTAssertEqual(table.begin("p1", priority: .prefetch), .joined)
        XCTAssertEqual(table.begin("p1", priority: .prefetch), .joined)
        XCTAssertEqual(table.count, 1)
        // 回包仍用首次的代数核销。
        guard case .start(let generation) = first else { return XCTFail("expected start") }
        XCTAssertTrue(table.finish("p1", generation: generation))
    }

    /// 取消后再到的回包必须作废（代数不匹配），否则旧数据会盖掉新状态。
    func testCancelledPageResultIsRejected() {
        var table = Table()
        guard case .start(let generation) = table.begin("p1", priority: .prefetch) else {
            return XCTFail("expected start")
        }
        table.cancel("p1")
        XCTAssertFalse(table.finish("p1", generation: generation))
        XCTAssertEqual(table.count, 0)
    }

    /// 取消后同页重新发起拿到新代数；旧回包作废、新回包有效。
    func testRefetchAfterCancelUsesNewGeneration() {
        var table = Table()
        guard case .start(let old) = table.begin("p1", priority: .prefetch) else {
            return XCTFail("expected start")
        }
        table.cancel("p1")
        guard case .start(let new) = table.begin("p1", priority: .userVisible) else {
            return XCTFail("expected start")
        }
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(table.finish("p1", generation: old))
        XCTAssertTrue(table.finish("p1", generation: new))
    }

    func testFinishWithUnknownPageIsRejected() {
        var table = Table()
        XCTAssertFalse(table.finish("nope", generation: 1))
    }

    func testHigherPriorityUpgradesInPlace() {
        var table = Table()
        _ = table.begin("p1", priority: .prefetch)
        XCTAssertEqual(table.begin("p1", priority: .jump), .joined)
        // 升级后不再被低优先级抢占取消。
        XCTAssertTrue(table.cancelAll(below: .userVisible).isEmpty)
        XCTAssertTrue(table.isInFlight("p1"))
    }

    func testPreemptionCancelsOnlyLowerPriorities() {
        var table = Table()
        _ = table.begin("prefetch-1", priority: .prefetch)
        _ = table.begin("prefetch-2", priority: .prefetch)
        _ = table.begin("visible", priority: .userVisible)
        let cancelled = table.cancelAll(below: .userVisible)
        XCTAssertEqual(Set(cancelled), ["prefetch-1", "prefetch-2"])
        XCTAssertEqual(table.count, 1)
        XCTAssertTrue(table.isInFlight("visible"))
    }
}
