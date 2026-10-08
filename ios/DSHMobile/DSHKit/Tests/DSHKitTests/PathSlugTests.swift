import DSHKit
import XCTest

/// 路径分量规约（spec 007 T055）：三份缓存共用一条规则，且绝不允许逃出目录。
final class PathSlugTests: XCTestCase {

    func testKeepsHostIdsVerbatim() {
        XCTAssertEqual(PathSlug.slug("session-4faa7f5d-4124-4bc2-920d-547bf94a178e"),
                       "session-4faa7f5d-4124-4bc2-920d-547bf94a178e")
        XCTAssertEqual(PathSlug.slug("mac_a-1"), "mac_a-1")
    }

    func testNeutralisesPathEscapes() {
        // 点也不在允许集里，所以连 ".." 都不会出现：比"只挡斜杠"更严。
        XCTAssertEqual(PathSlug.slug("../../etc/passwd"), "______etc_passwd")
        XCTAssertEqual(PathSlug.slug("a/b\\c:d"), "a_b_c_d")
        let escaped = PathSlug.slug("../x")
        XCTAssertFalse(escaped.contains("/"))
        XCTAssertFalse(escaped.contains("."))
    }

    func testEmptyBecomesAUsableNameAndLongValuesAreCapped() {
        XCTAssertEqual(PathSlug.slug(""), "unknown")
        XCTAssertEqual(PathSlug.slug("///"), "___")
        XCTAssertEqual(PathSlug.slug(String(repeating: "a", count: 400)).count, 120)
    }

    func testTheThreeCachesShareOneRuleWhileTheOldTypeIsRetired() {
        XCTAssertEqual(SessionTranscriptCache.slug("a/b"), PathSlug.slug("a/b"))
        XCTAssertEqual(TranscriptStore.slug("a/b"), PathSlug.slug("a/b"))
    }
}
