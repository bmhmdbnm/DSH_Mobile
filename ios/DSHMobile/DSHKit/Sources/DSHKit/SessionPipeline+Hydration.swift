import Foundation

/// SessionPipeline 的磁盘水合半边（文件按职责拆分，沿用 `SessionPipeline+Streaming`
/// 与 `MessageStore+Records` 先例：主文件顶到 500 行上限）。
///
/// 纪律：区间集声称覆盖只是"磁盘应该有"的声明，不是事实。读盘短收（被淘汰、
/// 没落盘、库被清）的连续空洞必须并回网络缺口，交同一条「取不到就拉」路径补齐；
/// 区间集不回删（磁盘是缓存，崩丢由取用兜底）。
extension SessionPipeline {

    /// 区间集声称覆盖、但热窗口已淘汰的段：读盘补回热窗口。
    /// 返回本次水合的记录（调用方据此发 diff）；磁盘短收的连续空洞
    /// 并入 `missing`，走同一条网络补齐路径（磁盘只是缓存，崩丢由
    /// 「取用失败即拉取」兜底，区间集不回删）。
    func hydrateCoveredSpans(
        of range: ClosedRange<Int>, missing: inout [RangeIndex.Span]
    ) async -> [SessionRecord] {
        guard let store, !ranges.isEmpty else { return [] }
        var hydrated: [SessionRecord] = []
        let coveredSpans = ranges.spans.filter {
            $0.end >= range.lowerBound && $0.start <= range.upperBound
        }
        for span in coveredSpans {
            let from = max(span.start, range.lowerBound)
            let to = min(span.end, range.upperBound)
            let absent = (from...to).filter { hotWindow[$0] == nil }.sorted()
            guard !absent.isEmpty else { continue }
            let diskRecords = (try? await store.records(
                scope: scope, sessionId: sessionId, in: from...to)) ?? []
            var found = Set<Int>()
            for record in diskRecords where record.event.seq >= from && record.event.seq <= to {
                mergeIntoHotWindow(record)
                found.insert(record.event.seq)
                hydrated.append(record)
            }
            // 磁盘短收：把连续的空洞段并入 missing。
            var runStart: Int?
            var previous = Int.min
            for seq in absent where !found.contains(seq) {
                if runStart == nil { runStart = seq }
                if seq != previous + 1, let start = runStart, start < seq {
                    missing.append(RangeIndex.Span(start, previous))
                    runStart = seq
                }
                previous = seq
            }
            if let start = runStart {
                missing.append(RangeIndex.Span(start, previous))
            }
        }
        return hydrated
    }
}
