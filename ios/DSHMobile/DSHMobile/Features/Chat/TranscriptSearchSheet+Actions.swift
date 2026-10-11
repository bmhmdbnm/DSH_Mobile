import DSHKit
import SwiftUI

/// 搜索面板的动作半边（调度、执行、翻页预读）。从 TranscriptSearchSheet.swift 拆出，
/// 主文件只留视图（500 行上限，宪法）。
///
/// 注意：这里的成员访问的是主文件里 internal 的 @State，编译期仍是同一个 View 值类型，
/// 只是物理上分了文件。
extension TranscriptSearchSheet {

    // MARK: - 搜索调度

    /// 现在要搜什么（筛选 + 关键词）——同时也是"要不要重搜"的指纹。
    var searchKey: String {
        "\(onlyMine ? "mine" : "all")|\(query.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 排一次搜索。打字时每敲一下都会把上一次排的取消掉，所以只有停下来那一次会真的跑；
    /// 指纹没变（比如只是内容变大）也走这条路，但 `immediate` 之外的重复输入不会重搜。
    func scheduleSearch(immediate: Bool = false) {
        let key = searchKey
        searchTask?.cancel()
        latestSearchKey = key
        isSearchPending = true
        ViewportProbe.note("search.schedule", ["key": key, "immediate": immediate ? "1" : "0"])
        if immediate {
            searchTask = Task { @MainActor in await performSearch(key: key) }
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.typingDebounce))
            if Task.isCancelled {
                // 打字期间被打断的那些：探针留痕，用来证明"只有最后一次落地"。
                ViewportProbe.note("search.dropped", ["key": key])
                return
            }
            await performSearch(key: key)
        }
    }

    // MARK: - 执行

    /// 真正的匹配。
    ///
    /// 三条路，互不含糊（T040）：
    ///   * 「只看我的提问」→ **只读本地**（`record` / `record_fts`，零网络），未灌全也照读，
    ///     完整性交给顶部「同步中…」状态行，**没有**连接器岔路；
    ///   * 关键词 ≥2 字且连接器能搜整个会话 → 连接器（`sessionFind`），覆盖整会话；
    ///   * 其余 → 本地已加载的那一段（老连接器的降级，FR-015/FR-036）。
    @MainActor
    func performSearch(key: String) async {
        lastSearchKey = key
        let items = model.searchItems
        let query = self.query
        let mine = onlyMine
        let started = Date()
        var found: [TranscriptSearchHit] = []
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if mine {
            // 来源先落定再 await：否则这段窗口里 `requestLoad()` 可能按上一次的
            // `.connector` 去要一页「我的提问」（那正是要删掉的那条路）。
            searchSource = .localStore
            searchCursor = nil
            pageHasMore = false
            // 完整性标记与命中同属一次本地读路径：先问标记，灌全时状态行不会闪。
            await refreshUserInputSyncState(rerunOnSync: false)
            found = await model.localUserInputHits(query: query)
        } else if model.connectorSearchesWholeSession, keyword.count >= 2 {
            // 只有"搜全部内容"才走连接器；`onlyMine` 恒为 false（上面已独占），
            // 所以这里不再带 roles 过滤。
            let page = await model.searchPage(query: query, onlyMine: false, limit: 50)
            found = page?.hits ?? []
            searchCursor = page?.cursor
            pageHasMore = page?.hasMore ?? false
            searchSource = .connector
        } else {
            // 没有这个能力：老办法（本地、只搜已加载的那一段），并且**离开主线程**匹配。
            found = await Task.detached(priority: .userInitiated) {
                TranscriptSearch.hits(in: items, query: query, onlyMine: mine)
            }.value
            searchCursor = nil
            pageHasMore = false
            searchSource = .localWindow
        }
        if Task.isCancelled { return }
        ViewportProbe.note("search.run", [
            "key": key,
            "source": searchSource.rawValue,
            "items": String(items.count),
            "hits": String(found.count),
            "ms": String(format: "%.0f", Date().timeIntervalSince(started) * 1000),
        ], force: true)
        if latestSearchKey == key { isSearchPending = false }
        guard latestSearchKey == key else { return }
        hits = found
        // 结果集换了（切筛选、改关键词、缓冲变大）：可见集合按 id 保留，余量重算一次。
        visibleHitIds = visibleHitIds.filter { id in found.contains { $0.id == id } }
        prefetchIfRunningLow()
    }

    func pick(_ hit: TranscriptSearchHit) {
        onPick(hit)
        dismiss()
    }

    // MARK: - 「同步中…」状态（T040）

    /// 读一次完整性标记（本地一次 SQLite 索引读，零网络）并落到面板状态。
    ///
    /// 由 `performSearch` 的本地路径和 `watchUserInputSyncState()` 共同调用。
    /// `rerunOnSync` 只在"由未灌全翻到已灌全"时重跑查询：列表无缝变完整，
    /// 读者不用关掉面板再打开。`performSearch` 自己调时传 false（避免自触发的重复搜）。
    func refreshUserInputSyncState(rerunOnSync: Bool = true) async {
        let synced = await model.userInputsSynced()
        guard synced != isUserInputsSynced else { return }
        isUserInputsSynced = synced
        ViewportProbe.note("search.sync", ["synced": synced ? "1" : "0"], force: true)
        if synced, rerunOnSync { scheduleSearch(immediate: true) }
    }

    /// 未灌全时每 1.5 秒轻量查一次标记，灌全立刻撤掉「同步中…」。
    ///
    /// 为什么是轮询而不是回填完成时的通知：回填跑在列表页的冷启动任务里
    ///（`SessionListModel+ColdStart`），它拿不到当前这个面板；为一条状态行铺一层
    /// 通知管线不值当。这里查的是一行索引读，只在「只看我的提问」且未灌全时才转。
    func watchUserInputSyncState() async {
        guard onlyMine else { return }
        while !Task.isCancelled {
            await refreshUserInputSyncState()
            guard isUserInputsSynced == false else { return }
            try? await Task.sleep(for: .milliseconds(Self.syncPollMilliseconds))
        }
    }

    // MARK: - 翻页预读

    /// 往搜索缓冲里再取一页（**不动时间线**，也就不会挪动读者的位置）。
    /// 可见范围之外还剩几条？不够 `prefetchAhead` 就继续往前读——读完再判一次，
    /// 所以"一旦触发就会连着读到够"（页里通常只有几条提问，一次要读好几页才攒够 10 条）。
    func prefetchIfRunningLow(fallbackWhenNothingVisible: Bool = false) {
        // localStore（「我问过的」本地全量库）没有"更早的一页"可预读。
        guard searchSource != .localStore,
              !isLoadingMore, model.canExtendSearch, !hits.isEmpty else { return }
        // 打字期间不读：那会一边追加行一边重排列表，和输入抢主线程（也正是"卡"的来源）。
        guard !isSearchPending else { return }
        let lastVisible = hits.lastIndex { visibleHitIds.contains($0.id) }
        guard let lastVisible else {
            // 还没有行上报可见（首次布局那一瞬间）：只有底部那行露面时才兜底读一页。
            if fallbackWhenNothingVisible { requestLoad() }
            return
        }
        let remaining = hits.count - 1 - lastVisible
        ViewportProbe.note("search.buffer", [
            "rows": String(hits.count),
            "visible": String(visibleHitIds.count),
            "remaining": String(remaining),
        ])
        guard remaining <= Self.prefetchAhead else { return }
        // 一轮滑动（或一次筛选/关键词变更）里最多自动读 `maxScrollDrivenLoads` 页：
        // 读者再滑一下就又有这么多。**不能**按"有产出就一直读"放开——关键词命中很多时
        // 那条路会把整段历史读完（2026-09-25 实测：搜 circleboom 一次读掉 9 页到 seq 0）。
        let produced = hits.count > lastRowCount
        guard scrollDrivenLoads < Self.maxScrollDrivenLoads else {
            ViewportProbe.note("search.prefetch.budget", [
                "rows": String(hits.count),
                "remaining": String(remaining),
                "budget": String(scrollDrivenLoads),
            ], force: true)
            return
        }
        scrollDrivenLoads += 1
        ViewportProbe.note("search.prefetch", [
            "rows": String(hits.count),
            "remaining": String(remaining),
            "produced": produced ? "1" : "0",
            "budget": String(scrollDrivenLoads),
        ], force: true)
        requestLoad()
    }

    /// 起一次"往前读一页"。同步占住 `isLoadingMore`，避免同一批行事件里起好几个。
    ///
    /// `onlyMine` 直接挡掉：「我问过的」是本地全量库，没有更早的一页，也**没有**网络可退
    ///（T040）——这里不挡的话，竞态窗口里会按上一次的来源去要连接器分页。
    func requestLoad() {
        guard !isLoadingMore, model.canExtendSearch, !onlyMine else { return }
        isLoadingMore = true
        Task { await loadMore() }
    }

    func loadMore() async {
        // 探针：记下"追加前后"的条数与**第一条**。追加只发生在列表末尾，所以第一条
        // 必须始终不变——这是"加载无感、列表不跳"的机器判据（`firstBefore == firstAfter`）。
        let firstBefore = hits.first?.id
        let countBefore = hits.count
        switch searchSource {
        case .localStore:
            // 正常路径到不了这里（`requestLoad` 已挡掉 onlyMine）：万一别人改了调用点，
            // 也只是重读一次本地，绝不联网。
            await performSearch(key: searchKey)
        case .connector:
            // 连接器分页：直接要下一页命中（它自己扫整个会话），不走本地缓冲。
            if let page = await model.searchPage(query: self.query, onlyMine: false,
                                                 cursor: searchCursor, limit: 50) {
                let existing = Set(hits.map(\.id))
                hits.append(contentsOf: page.hits.filter { !existing.contains($0.id) })
                searchCursor = page.cursor
                pageHasMore = page.hasMore
            }
        case .localWindow:
            await model.extendSearchHistory()
            await performSearch(key: searchKey)
        }
        lastRowCount = hits.count
        isLoadingMore = false
        ViewportProbe.note("search.page", [
            "before": String(countBefore),
            "after": String(hits.count),
            "firstBefore": firstBefore ?? "-",
            "firstAfter": hits.first?.id ?? "-",
            "kept": firstBefore == hits.first?.id ? "1" : "0",
        ], force: true)
        // 追加进来的行在屏幕外，不会再触发 `onAppear`；所以这里主动再判一次余量，
        // 不够就接着读（"触发了就继续预加载"）。放在 `isLoadingMore` 放下之后，
        // 否则会被自己的 guard 挡掉（上一版就是这样：连读其实是靠别的行事件凑出来的）。
        prefetchIfRunningLow()
    }
}
