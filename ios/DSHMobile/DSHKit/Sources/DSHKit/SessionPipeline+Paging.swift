import Foundation

/// 页对齐工具（从 SessionPipeline 主文件拆出：主文件逼近 500 行上限）。
/// 页大小对齐的取页边界（spec 009 §6）与淘汰锚点的计算都收在这里。
extension SessionPipeline {

    /// 覆盖某缺口的对齐页集合（页大小对齐，spec §6 页边界）。
    func alignedPages(covering span: RangeIndex.Span) -> [ClosedRange<Int>] {
        var pages: [ClosedRange<Int>] = []
        var start = alignedStart(for: span.start)
        while start <= span.end {
            pages.append(start...(start + pageSize - 1))
            start += pageSize
        }
        return pages
    }

    func alignedPage(containing seq: Int) -> ClosedRange<Int> {
        let start = alignedStart(for: seq)
        return start...(start + pageSize - 1)
    }

    func alignedStart(for seq: Int) -> Int {
        max(1, ((max(1, seq) - 1) / pageSize) * pageSize + 1)
    }

    /// 淘汰锚点：请求区间的中点。回看水合时淘汰离锚点更远的一端，
    /// 避免把读者正在看的段抽走（T026：水合→淘汰→空白带的死循环）。
    static func anchor(of range: ClosedRange<Int>) -> Int {
        (range.lowerBound + range.upperBound) / 2
    }

    /// 服务端是否**明确说**这页到头了（spec 可见性兜底 / T038「空页即异常」）：
    /// 只有拉的是最底页（对齐起点 1）且 `hasMore == false` 或被日志裁剪（clamped）
    /// 才算「已到最早」。空回包 + 这个判定 = 正常终态（置 topExhausted）；
    /// 空回包 + 判定不成立 = 可重试失败（见 SessionPipeline.fetchPage）。
    /// 网络失败永远不得当作到底。
    static func reachedEnd(_ page: FetchPage, requested: ClosedRange<Int>) -> Bool {
        requested.lowerBound == 1 && (page.hasMore == false || page.clamped)
    }

    // MARK: - gap 行派生（从主文件拆出，同一 500 行上限）

    /// 缺口行由区间集派生（spec「缺口行的生命周期」）：窗口 = 最老…最新。
    func currentGaps() -> [GapRow] {
        guard let oldest = ranges.oldest, let newest = ranges.newest, oldest <= newest else { return [] }
        return ranges.gaps(within: oldest...newest).map { span in
            GapRow(start: span.start, end: span.end, status: gapStatus(for: span))
        }
    }

    private func gapStatus(for span: RangeIndex.Span) -> GapRow.Status {
        // 该缺口覆盖的对齐页里有到 3 次失败的 → retryable。
        let firstPage = alignedPages(covering: span).first
        if let key = firstPage?.lowerBound, failureCounts[key, default: 0] >= Self.maxRetries {
            return .failed(retryable: true)
        }
        return .loading
    }

    /// 丢弃一段不打算自动补的缺口（T026 修复 US3 遗留：>5 页降级直跳
    /// 最新页后，中间缺口没有在任何在飞拉取里，停在 .loading 永远转圈）。
    /// 置为可重试失败态：用户点它走 `retry(range:)` 才真拉，符合
    /// 「丢弃中间段」的省流量语义（spec 场景 7）。只标 covering 页的
    /// 失败计数，不发网络；区间集不变（缺口仍在，只是状态变了）。
    public func abandonGap(_ range: ClosedRange<Int>) {
        guard range.lowerBound <= range.upperBound else { return }
        for page in alignedPages(covering: RangeIndex.Span(range.lowerBound, range.upperBound)) {
            failureCounts[page.lowerBound] = Self.maxRetries
        }
        emit(Diff(gaps: currentGaps()))
    }
}
