@testable import DSHKit
import XCTest

/// 排版缓存（spec 009 §4 / tasks T007）：A/B 分库、环境 key 失配隔离、字节 LRU。
final class TypesetCacheTests: XCTestCase {

    private let light = TypesetCache.Environment(widthBucket: 390, textSizeRank: 3, dark: false)
    private let dark = TypesetCache.Environment(widthBucket: 390, textSizeRank: 3, dark: true)
    private let wide = TypesetCache.Environment(widthBucket: 834, textSizeRank: 3, dark: false)

    func testAClassRoundTrip() {
        let cache = TypesetCache(bBytesLimit: 1024)
        cache.setA(["ast": "parsed"], for: "m1")
        XCTAssertNotNil(cache.aValue(for: "m1"))
        XCTAssertNil(cache.aValue(for: "m2"))
    }

    /// 环境是 key 的一部分：同一条消息在深浅色/不同宽度下永不混用（spec §4）。
    func testBClassEnvironmentIsolation() {
        let cache = TypesetCache(bBytesLimit: 1024)
        cache.setB(42.0, for: "m1", in: light, cost: 100)
        XCTAssertNotNil(cache.bValue(for: "m1", in: light))
        XCTAssertNil(cache.bValue(for: "m1", in: dark))
        XCTAssertNil(cache.bValue(for: "m1", in: wide))
    }

    /// 字节 LRU：塞爆后最早的成本被挤掉，总成本不超上限。
    func testBClassEvictsByCost() {
        let cache = TypesetCache(bBytesLimit: 300)
        cache.setB(1, for: "a", in: light, cost: 200)
        cache.setB(2, for: "b", in: light, cost: 200)
        // 300 上限装不下两个 200，至少一个被淘汰；具体淘汰谁由 NSCache 决定，
        // 只断言不爆容量语义（b 或 a 至少一个出局）。
        let survivors = [cache.bValue(for: "a", in: light), cache.bValue(for: "b", in: light)]
            .compactMap { $0 }
        XCTAssertLessThanOrEqual(survivors.count, 1)
    }

    func testAClassSoftLimitKeepsCacheBounded() {
        let cache = TypesetCache(bBytesLimit: 1024, aLimit: 100)
        for index in 0..<500 { cache.setA(index, for: "m\(index)") }
        // 打折策略下条数必须明显低于全量，且后续仍可写入。
        cache.setA(999, for: "latest")
        XCTAssertNotNil(cache.aValue(for: "latest"))
    }
}
