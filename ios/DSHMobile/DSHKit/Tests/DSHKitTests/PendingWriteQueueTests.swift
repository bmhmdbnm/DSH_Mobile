import DSHKit
import XCTest

/// 批量落库队列（spec 009 架构决定 §3 / tasks T005）：
/// 按消息去重、条数与时间窗两种触发、drain 保序、流式不放大。
final class PendingWriteQueueTests: XCTestCase {

    func testSameKeyKeepsOnlyTheLatestValue() {
        var queue = PendingWriteQueue<Int, String>()
        queue.enqueue(1, "draft", now: 0)
        queue.enqueue(1, "draft-longer", now: 0)
        queue.enqueue(1, "final", now: 0)
        XCTAssertEqual(queue.count, 1)
        let batch = queue.drain(now: 100)
        XCTAssertEqual(batch.map(\.key), [1])
        XCTAssertEqual(batch.map(\.value), ["final"])
    }

    /// 流式场景：同一行 50 次更新只落一次盘（写盘放大为零）。
    func testStreamingCoalescesToOneWrite() {
        var queue = PendingWriteQueue<Int, String>()
        for tick in 0..<50 { queue.enqueue(7, "chunk-\(tick)", now: 0) }
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.drain(now: 0).first?.value, "chunk-49")
    }

    func testFlushTriggeredByBatchSize() {
        var queue = PendingWriteQueue<Int, Int>(maxBatch: 3, flushInterval: 60)
        queue.enqueue(1, 1, now: 0)
        queue.enqueue(2, 2, now: 0)
        XCTAssertFalse(queue.shouldFlush(now: 0))
        queue.enqueue(3, 3, now: 0)
        XCTAssertTrue(queue.shouldFlush(now: 0))
    }

    func testFlushTriggeredByInterval() {
        var queue = PendingWriteQueue<Int, Int>(maxBatch: 100, flushInterval: 0.5)
        queue.enqueue(1, 1, now: 10)
        XCTAssertFalse(queue.shouldFlush(now: 10.4))
        XCTAssertTrue(queue.shouldFlush(now: 10.5))  // 时间窗从首次入队起算
        _ = queue.drain(now: 10.5)
        queue.enqueue(2, 2, now: 10.6)
        XCTAssertFalse(queue.shouldFlush(now: 11.0))
        XCTAssertTrue(queue.shouldFlush(now: 11.1))
    }

    func testDrainPreservesInsertionOrderWithDedupAtTail() {
        var queue = PendingWriteQueue<Int, String>()
        queue.enqueue(1, "a", now: 0)
        queue.enqueue(2, "b", now: 0)
        queue.enqueue(3, "c", now: 0)
        queue.enqueue(1, "a2", now: 0)  // 去重后移到队尾
        XCTAssertEqual(queue.drain(now: 0).map(\.key), [2, 3, 1])
    }

    func testEmptyQueueNeverFlushes() {
        let queue = PendingWriteQueue<Int, Int>()
        XCTAssertFalse(queue.shouldFlush(now: 9999))
    }
}
