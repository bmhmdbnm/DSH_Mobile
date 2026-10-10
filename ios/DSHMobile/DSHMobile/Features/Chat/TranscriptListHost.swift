import DSHKit
import SwiftUI
import UIKit

/// 转写列表的新宿主（spec 008）。
///
/// 与 007 的 SwiftUI `List` 的关键差别：**插入/丢弃与 `contentOffset` 修正发生在同一次
/// 更新里**——先把新行插进 diffable 快照并 `layoutIfNeeded()`，量出锚点行在内容坐标里的
/// 位移，再把同样多的位移加到 `contentOffset` 上。全程**不做"滚到某一行"**：那正是 007
/// 崩溃的来源（`_validateScrollingTargetIndexPath`：更新与滚动是两次独立动作，中间那一瞬
/// 目标行可能已经不存在）。
///
/// 行视图继续用现有的 SwiftUI 行视图（`UIHostingConfiguration` 包一层），所以视觉按 spec
/// 的"等价"验收，不做逐像素对齐。
/// SwiftUI ↔ 宿主之间的桥（spec 008 的 US1）。
///
/// `items` 每次变化都做一次差集：**往上插了一页**就 `prepend`（原子修正位移），
/// 其它情况（换窗口/跳转/裁剪）就整批 `setRows` 并锚回指定行。
struct TranscriptListRepresentable: UIViewRepresentable {

    let items: [TimelineItem]
    /// 行视图：由 `ChatView` 传进来（直接用它自己的 `row(_:)`，两条宿主共用同一套行）。
    let makeRow: (TimelineItem) -> AnyView
    /// 钉到底部（打开会话与内容变化时）。
    let pinToBottom: Bool
    /// 探针出口。
    let onDiagnostic: (String, [String: String]) -> Void
    /// 读者滑到顶部附近：调用方负责取页（`ChatModel.loadOlder`）。
    let onNearTop: () -> Void
    /// 滚动几何回调（007 的 `older.sentinel` 等价）。
    let onScroll: (CGFloat) -> Void
    /// 跟随尾部时按预算丢最老端（入参是"屏幕大约能放几行"，返回该丢几行；0 = 不丢）。
    /// 传屏高进去是为了让保留带至少覆盖一两屏——否则丢弃会把内容压到比一屏还短
    /// （run 20261008-230106 的现象：窗口只剩 20 行、视口滚不动、连补页都不再触发）。
    let onBudgetCheck: (Int) -> Int
    /// `-DSHProbeOlderScroll` 的 uikit 驱动轮数（0 = 不驱动）。
    let driveRounds: Int
    /// 驱动开始前调用：真实手指上滑会把"跟随中"关掉，驱动必须做同样的事，
    /// 否则"回到底部"按钮永远不会出现（2026-10-08 实测：探针里 `following=1`、按钮不可见）。
    let onDriveBegin: () -> Void
    /// 该回收这些行（宿主判定，调用方执行）。
    let onReclaim: ([String]) -> Void
    /// 这些 seq 需要内容（调用方从本地库读回来后调用 `coordinator.rehydrate(items:)`）。
    let onNeedRehydrate: ([Int]) -> Void
    /// 读者是否贴在最新那一头（唯一可靠的"跟随"依据）。
    let onBottomChanged: (Bool) -> Void
    /// 跳转目标行（spec 008 的 US2）：换窗口之后由宿主滚过去，**不经过 SwiftUI 的 ScrollViewProxy**。
    let jumpToId: String?
    /// 把宿主实例交回给 `ChatView`（回收/水合要用它把行交回来）。
    let hostRef: Binding<TranscriptListHost?>
    /// 009 数据源（MessagePipeline 快照）模式：每次 `items` 变化都是一次多段
    /// 混合变更，必须作为**一次原子更新**提交（统一锚位移修正，tasks T015），
    /// 不再走「prepend / setRows 二选一」的启发式（那会拆成两次提交或误锚尾部）。
    var atomicApply: Bool = false

    func makeUIView(context: Context) -> TranscriptListHost {
        let host = TranscriptListHost()
        context.coordinator.onBudgetCheck = onBudgetCheck
        host.makeRow = makeRow
        host.onDiagnostic = onDiagnostic
        host.onScroll = onScroll
        host.onBottomChanged = onBottomChanged
        host.onNearTop = { [weak coordinator = context.coordinator] in
            coordinator?.requestOlder()
        }
        host.apply(.setRows(items, anchorId: items.last?.id))
        context.coordinator.known = Set(items.map(\.id))
        context.coordinator.host = host
        context.coordinator.onNearTop = onNearTop
        context.coordinator.onDiagnostic = onDiagnostic
        host.onReclaim = onReclaim
        host.onNeedRehydrate = { [weak coordinator = context.coordinator] seqs in
            coordinator?.onNeedRehydrate?(seqs)
        }
        context.coordinator.onNeedRehydrate = onNeedRehydrate
        context.coordinator.onDriveBegin = onDriveBegin
        context.coordinator.startDriveIfNeeded(rounds: driveRounds)
        context.coordinator.maybeForceRehydrate(host: host)
        hostRef.wrappedValue = host
        return host
    }

    func updateUIView(_ host: TranscriptListHost, context: Context) {
        let known = context.coordinator.known
        let incoming = items.filter { !known.contains($0.id) }
        let removed = known.subtracting(items.map(\.id))
        if atomicApply {
            // 009：多段混合变更一次原子提交（统一锚位移修正，tasks T015）。
            host.apply(.reconcile(items, reason: "pipeline"))
        } else if !removed.isEmpty {
            // 变少了（裁剪/换窗口）⇒ 整批重来；只多出来且都在前面 ⇒ 原子前插。
            host.apply(.setRows(items, anchorId: items.last?.id))
        } else if !incoming.isEmpty {
            if TranscriptListSection.isPrepend(incoming, current: host.rows.compactMap(\.item)) {
                host.apply(.prepend(incoming))
            } else {
                host.apply(.setRows(items, anchorId: items.last?.id))
            }
        }
        if pinToBottom, let last = items.last?.id { host.scrollTo(id: last) }
        context.coordinator.known = Set(items.map(\.id))
        if pinToBottom { host.pinAfterUpdate() }
        context.coordinator.finishOlderIfNeeded(host: host, items: items)
        // 强制水合要等**真有行被回收**之后才有东西可水合：`makeUIView` 那一刻还没回收，
        // 所以在每次更新时也问一次（2026-10-08 实测：只在 makeUIView 里问 ⇒ request=0）。
        context.coordinator.maybeForceRehydrate(host: host)
        if let target = jumpToId, target != context.coordinator.lastJumped,
           items.contains(where: { $0.id == target }) {
            context.coordinator.lastJumped = target
            host.scrollTo(id: target)
            onDiagnostic("search.jump", ["item": target, "via": "list-host"])
        }
        // 跟随尾部时按预算丢最老端：宿主做原子丢弃（同一批 id），模型同步丢。
        // 只调一次：`onBudgetCheck` **有副作用**（它会把模型端该丢的行也丢掉），
        // 调两次会让"探针那次"先把行丢了、"执行那次"拿到 0（2026-10-08 实测：`window.trimmed` 反而消失）。
        let budgetCount = context.coordinator.onBudgetCheck?(host.visibleRowEstimate) ?? 0
        onDiagnostic("list.budget", [
            "count": String(budgetCount),
            "pin": pinToBottom ? "1" : "0",
            "items": String(items.count),
        ])
        if pinToBottom, budgetCount > 0 {
            let victims = items.prefix(budgetCount).map(\.id)
            host.apply(.dropOldest(count: budgetCount))
            onDiagnostic("window.trimmed", [
                "dropped": String(budgetCount),
                "items": String(max(0, items.count - budgetCount)),
                "oldest": victims.last ?? "-",
            ])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 把"取页 → 发 `older.pump`"和 spike 用的驱动收在这里：
    /// SwiftUI 的视图结构体每次更新都会重建，只有 coordinator 能跨更新记住状态。
    @MainActor
    final class Coordinator {
        var known: Set<String> = []
        weak var host: TranscriptListHost?
        var onNearTop: (() -> Void)?
        var onDiagnostic: ((String, [String: String]) -> Void)?
        var onBudgetCheck: ((Int) -> Int)?
        var onDriveBegin: (() -> Void)?
        var onNeedRehydrate: (([Int]) -> Void)?
        /// 本地库取回内容之后，把行交回宿主水合（真实路径的入口）。
        private var forcedRehydrate = false

        /// `-DSHProbeForceRehydrate`：把第一条已回收的行按**真实路径**要回来。
        /// 这条链与"读者滑回去"完全同源（同一个 `onNeedRehydrate` 回调），只是触发点不同。
        func maybeForceRehydrate(host: TranscriptListHost) {
            guard ProbeVariants.forceRehydrate, !forcedRehydrate else { return }
            guard let reclaimed = host.rows.firstIndex(where: { $0.isReclaimed }) else { return }
            guard case .reclaimed(let seq, _, _) = host.rows[reclaimed].state else { return }
            forcedRehydrate = true
            onDiagnostic?("list.rehydrate.request", ["seqs": "1", "seq": String(seq),
                                                     "rows": String(host.rows.count)])
            onNeedRehydrate?([seq])
        }

        func rehydrate(items: [TimelineItem]) {
            host?.rehydrate(items: items)
        }
        private var waitingForOlder = false
        private var driveStarted = false
        private var lastKnownCount = 0
        private var lastRequestAt = Date.distantPast
        var lastJumped: String?

        func requestOlder() {
            // 闩锁要能被"超时"打开：取页失败或 `updateUIView` 没再进来时，`waitingForOlder`
            // 会一直挂着，之后每次 `requestOlder` 都被它挡掉（2026-10-08 实测：整轮只剩 1 次请求、
            // 于是只补到 1 页、只丢 2 次）。8 秒没人来收，就允许再请求一次。
            if waitingForOlder, Date().timeIntervalSince(lastRequestAt) < 8 { return }
            lastRequestAt = Date()
            waitingForOlder = true
            onDiagnostic?("older.request", ["items": String(host?.rows.count ?? 0)])
            onNearTop?()
        }

        /// 取页回来（`items` 变多）之后，把 007 的 `older.pump` 等价出来：
        /// `kept` 由宿主最近一次 `settle` 的残差换算（≤8pt 即 1）。
        ///
        /// `items` 用**取页之后**的条数：原来在 `items` 还没变多时就把探针发了，字段是旧值
        /// （run 20261008-222846 实测第一条 `items=54` 而页已落地）。
        func finishOlderIfNeeded(host: TranscriptListHost, items: [TimelineItem]) {
            guard waitingForOlder, items.count > lastKnownCount, let settle = host.lastSettle else {
                // 诊断：`older.pump` 没发出来时，说明卡在哪一条守卫上。
                if waitingForOlder {
                    onDiagnostic?("older.pump.skip", [
                        "grew": items.count > lastKnownCount ? "1" : "0",
                        "settle": host.lastSettle == nil ? "0" : "1",
                        "items": String(items.count),
                    ])
                }
                lastKnownCount = max(lastKnownCount, items.count)
                return
            }
            lastKnownCount = items.count
            waitingForOlder = false
            onDiagnostic?("older.pump", [
                "items": String(items.count),
                "anchor": host.currentAnchorId ?? "-",
                "hasOlder": "1",
                "kept": settle.ok ? "1" : "0",
            ])
        }

        /// `-DSHProbeOlderScroll <n>`：把视口送到顶端 n 次（007 的驱动在 uikit 下的等价物）。
        func startDriveIfNeeded(rounds: Int) {
            guard rounds > 0, !driveStarted else { return }
            driveStarted = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))   // 与 007 的驱动一致：等首屏钉底
                self?.onDriveBegin?()
                for round in 1...rounds {
                    guard let self, let host = self.host else { return }
                    // 先回到新的一头再往上滑：宿主只在"离开顶端 120pt 以上"之后才重新武装
                    // `onNearTop`（这是防抖，产品里由真实手指完成）。驱动只 scrollToTop 的话
                    // 第一轮之后 distance 一直是 0，永远不再触发补页——2026-10-08 实测就是这样
                    // 只补到 4 页、只丢 1 次。
                    host.scrollToBottom()
                    try? await Task.sleep(for: .milliseconds(400))
                    self.onDiagnostic?("older.drive", [
                        "round": String(round), "phase": "up",
                        "items": String(host.rows.count),
                    ])
                    host.scrollToTop()
                    try? await Task.sleep(for: .seconds(3))
                    // 驱动还要能"滑回被回收的那一段"：只在两端跳的话，被回收的往往在中间，
                    // `near` 永远是 0，水合这条路在仿真器里就永远验不到（2026-10-08 实测）。
                    if let reclaimed = host.rows.first(where: { $0.isReclaimed })?.id {
                        self.onDiagnostic?("older.drive", ["round": String(round), "phase": "reclaimed"])
                        host.scrollTo(id: reclaimed)
                        try? await Task.sleep(for: .milliseconds(2000))
                    }
                }
                self?.onDiagnostic?("older.drive", ["phase": "done",
                                                    "items": String(self?.host?.rows.count ?? 0)])
            }
        }
    }
}

@MainActor
final class TranscriptListHost: UIView, UICollectionViewDelegate {

    /// 宿主对上层暴露的指令（契约 §1）。
    enum Command {
        case setRows([TimelineItem], anchorId: String?)
        case prepend([TimelineItem])
        case dropOldest(count: Int)
        case reclaim([String])
        case rehydrate([String])
        /// 一次原子提交的多段混合变更（spec 009 tasks T015）：头部插入 + 缺口
        /// 生灭 + 尾部更新合在同一次快照应用里；位移修正走唯一位移锚
        /// （视口顶部首个完整可见行 + 行内偏移，上方高度差汇总一次应用）。
        case reconcile([TimelineItem], reason: String)
    }

    private(set) var rows: [TranscriptRowPayload] = []
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!

    /// 行视图构造：由 `ChatView` 注入（它知道怎么把 `TimelineItem` 画出来）。
    var makeRow: ((TimelineItem) -> AnyView)?
    /// 诊断出口（`ViewportProbe` 或 spike 自己接）。
    var onDiagnostic: ((String, [String: String]) -> Void)?
    /// 滚动几何：距内容顶端的距离（点）。
    var onScroll: ((CGFloat) -> Void)?
    /// 读者滑到顶部附近——**只在"靠近"这一次里触发一次**，离开足够远才重新武装。
    var onNearTop: (() -> Void)?
    /// 读者是否贴在最新那一头（由滚动几何算，不信拖动位移）。
    var onBottomChanged: ((Bool) -> Void)?
    /// 读者滚走（离开底部）时撤销"回到底部"的意图。
    func noteUserMovedAwayFromBottom() { wantsBottom = false }
    /// 内容变了之后要不要继续钉底：**只有本来就在底部**（或按钮刚点过）才钉。
    /// 这条替代了原来"用时间窗口猜程序化滚动"的做法——那套会把读者 600ms 内的真实上滑
    /// 误判成我们自己的滚动，于是内容一变就把会话拽回底部（真机反馈第 2 条）。
    func pinAfterUpdate() {
        guard wantsBottom || lastReportedAtBottom else { return }
        setOffsetToBottom()
    }

    /// 把偏移直接设到底（**不用 `scrollToItem`**：`apply(snapshot)` 是异步的，
    /// 同一轮里 `scrollToItem` 打的是旧数据源的下标，UIKit 会忽略——真机反馈"点了仍无效"，
    /// 探针里也是 `before == after`）。
    func setOffsetToBottom() {
        collectionView.layoutIfNeeded()
        let bottom = max(-collectionView.adjustedContentInset.top,
                         collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
                            - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }
    /// "回到底部"的意图：一次点击之后**持续满足**，直到真的到了底部。
    /// 一次性的 `scrollToItem` 会被在飞的批量更新吞掉——真机反馈过"点了仍无效"。
    private var wantsBottom = false
    /// 贴底容差（点）：在这个范围内就算"在最新那一头"。
    static let bottomSlack: CGFloat = 40

    /// 预取余量：一屏半。
    private func prefetchMargin() -> CGFloat {
        max(240, collectionView.bounds.height * 1.5)
    }

    /// 该回收这些行（由调用方决定最终是否回收）。
    var onReclaim: (([String]) -> Void)?
    /// 这些 seq 需要把内容要回来（调用方从本地库读，0 网络）。
    var onNeedRehydrate: (([Int]) -> Void)?
    private var reclaimCheckTask: Task<Void, Never>?
    /// 最近一次补页后的残差（用来把 007 的 `older.pump kept` 等价出来）。
    private(set) var lastSettle: (moved: CGFloat, ok: Bool)?
    private var nearTopArmed = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setUp() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        // 行间距按"原来紧挨着"来：list 的 section 内边距、行内 hosting 的默认 margins 叠起来
        // 会多出一圈空白（2026-10-08 真机反馈：思考过程/工具件之间隔得太开）。三处一起清零。
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: configuration,
                                                         layoutEnvironment: environment)
            section.contentInsets = .zero
            section.interGroupSpacing = 0
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let self, let item = self.item(for: id) else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                self.makeRow?(item) ?? AnyView(Color.clear)
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    // MARK: - 指令

    func apply(_ command: Command) {
        switch command {
        case .setRows(let items, let anchorId):
            rows = TranscriptListSection.ordered(items).map { TranscriptRowPayload(item: $0) }
            applySnapshot()
            if let anchorId { scrollTo(id: anchorId, animated: false) }
            diagnostic("list.host", ["mode": "uikit", "rows": String(rows.count)])
        case .prepend(let items):
            prepend(items, reason: "page")
        case .dropOldest(let count):
            dropOldest(count)
        case .reclaim(let ids):
            for index in rows.indices where ids.contains(rows[index].id) { rows[index].reclaim() }
            diagnostic("list.reclaim", ["rows": String(ids.count),
                                        "bytes": String(payloadBytes()),
                                        "totalBytes": String(payloadBytes())])
        case .rehydrate(let ids):
            for index in rows.indices where ids.contains(rows[index].id) { rows[index].contentVersion += 1 }
            diagnostic("list.rehydrate", ["rows": String(ids.count), "ms": "0", "net": "0"])
        case .reconcile(let items, let reason):
            reconcile(items, reason: reason)
        }
    }

    /// 009 的统一锚一次提交（spec「唯一位移锚」/ tasks T015）。
    ///
    /// 与 `prepend`/`dropOldest` 同一套纪律——量锚、一次应用快照、把上方高度差
    /// 汇总后**一次**加回 `contentOffset`，残差超容差再修一次（仍只改 offset，
    /// 不滚到行）。区别只在两点：
    /// - 变更可以是多段混合（头部插入 + 缺口生灭 + 尾部更新），所以锚不能取
    ///   「当前第一行」（它可能正在被换掉），要取**视口顶部首个完整可见行**；
    /// - 被回收的行保留回收态（身份与高度不变，内容仍由水合路径要回）。
    /// 上一次 reconcile 应用的行签名（id + 内容签名）：都没变就整次跳过
    /// （SwiftUI 每次 body 重算都会路过这里，真去 apply + layoutIfNeeded
    /// 会把打字都变成一次布局——T015 的性能纪律）。
    private var lastReconcile: [(id: String, signature: String)] = []

    func reconcile(_ items: [TimelineItem], reason: String) {
        let started = CFAbsoluteTimeGetCurrent()
        let ordered = TranscriptListSection.ordered(items)
        let incoming = ordered.map { (id: $0.id, signature: Self.signature(of: $0)) }
        guard incoming.map(\.signature) != lastReconcile.map(\.signature)
                || incoming.map(\.id) != lastReconcile.map(\.id) else { return }
        var changedIds = Set<String>()
        for (index, pair) in incoming.enumerated() {
            guard index < lastReconcile.count, lastReconcile[index].id == pair.id else { continue }
            if lastReconcile[index].signature != pair.signature { changedIds.insert(pair.id) }
        }
        lastReconcile = incoming
        let anchorId = firstFullyVisibleRowId() ?? rows.first?.id
        let before = visualY(of: anchorId)
        let reclaimedById = Dictionary(
            rows.filter(\.isReclaimed).map { ($0.id, $0.state) },
            uniquingKeysWith: { old, _ in old })
        rows = ordered.map { item in
            var payload = TranscriptRowPayload(item: item)
            if let reclaimed = reclaimedById[item.id] { payload.state = reclaimed }
            return payload
        }
        applySnapshot(reloading: changedIds)
        collectionView.layoutIfNeeded()
        let after = visualY(of: anchorId)
        var delta = (after ?? 0) - (before ?? 0)
        if delta != 0 {
            collectionView.contentOffset.y += delta
            collectionView.layoutIfNeeded()
        }
        var residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        if abs(residual) > Self.tolerance {
            collectionView.contentOffset.y += residual
            collectionView.layoutIfNeeded()
            delta += residual
            residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        }
        diagnostic("list.reconcile", [
            "rows": String(rows.count),
            "deltaPt": String(format: "%.0f", delta),
            "ms": String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000),
            "reason": reason,
        ])
        settle(anchorId: anchorId ?? "-", moved: residual)
        satisfyBottomIntent()
        if distanceToTop() < prefetchMargin() {
            nearTopArmed = true
            onNearTop?()
        }
    }

    /// 行内容签名：身份之外「内容有没有变」的判定（相同 id 的行被更新时要
    /// reload cell，缺口行的三态也在签名里）。回收态保留原签名——内容没变。
    private static func signature(of item: TimelineItem) -> String {
        let base = "\(item.id)#\(TranscriptRowPayload(item: item).payloadBytes)"
        switch item.kind {
        case .gap(_, _, let status):
            return "\(item.id)|gap:\(status)"
        case .userMessage(_, _, let isSteering, let isPending, _):
            // pending→sent 原地替换不改字节数，状态位必须进签名，否则徽标永远停在"等待开始"。
            return "\(base)|u:\(isSteering):\(isPending)"
        case .toolCall(let invocation):
            return "\(base)|t:\(invocation.isRunning):\(invocation.isError)"
        default:
            return base
        }
    }

    /// 唯一位移锚（spec 009）：视口顶部**首个完整可见行**的 id。
    /// 量不到（行还没布局出来）时返回 nil，调用方退而用第一行。
    private func firstFullyVisibleRowId() -> String? {
        let top = collectionView.contentOffset.y
        for index in rows.indices {
            let path = IndexPath(item: index, section: 0)
            guard let attributes = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: path) else { continue }
            if attributes.frame.maxY <= top { continue }
            // 首个与视口相交的行：完整可见（minY 不低于视口顶）才够格当锚，
            // 否则继续找下一行——被切掉半行的锚会量出半个行高的假位移。
            if attributes.frame.minY >= top { return rows[index].id }
        }
        return nil
    }

    /// 往上插一页：量出锚点位移，同一次更新内把 offset 修回去。
    func prepend(_ items: [TimelineItem], reason: String) {
        let incoming = TranscriptListSection.ordered(items).map { TranscriptRowPayload(item: $0) }
        guard !incoming.isEmpty else { return }
        let anchorId = rows.first?.id ?? incoming.first?.id
        let before = visualY(of: anchorId)
        let started = CFAbsoluteTimeGetCurrent()
        rows.insert(contentsOf: incoming, at: 0)
        applySnapshot()
        collectionView.layoutIfNeeded()
        let layoutMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let after = visualY(of: anchorId)
        var delta = (after ?? 0) - (before ?? 0)
        if delta != 0 {
            collectionView.contentOffset.y += delta
            collectionView.layoutIfNeeded()
        }
        // 修正之后自检一次：锚点相对**插入前**的视觉位置还有多少残差，> 容差就再修一次
        // （**仍然只改 offset，不滚到行**）。
        var residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        if abs(residual) > Self.tolerance {
            collectionView.contentOffset.y += residual
            collectionView.layoutIfNeeded()
            delta += residual
            residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        }
        diagnostic("list.insert", ["rows": String(incoming.count),
                                   "deltaPt": String(format: "%.0f", delta),
                                   "ms": String(format: "%.0f", layoutMs),
                                   "reason": reason])
        settle(anchorId: anchorId ?? "-", moved: residual)
        // 补完一页之后如果读者还贴在顶部，就**继续要下一页**：真实手指一直往上拉时内容不再移动，
        // `scrollViewDidScroll` 也就不会再报"靠近顶端"，只在第一页之后停住
        // （2026-10-08 真机反馈："仍不能无限拉，中断了"）。这里由宿主自己续上，
        // 次数交给调用方的"还有没有更早"兜底（到日志开头就不再要）。
        satisfyBottomIntent()
        if distanceToTop() < prefetchMargin() {
            nearTopArmed = true
            onNearTop?()
        }
    }

    /// 按预算丢弃最老的已读行（spec 008 的 FR-002）。
    func dropOldest(_ count: Int) {
        guard count > 0, rows.count > count else { return }
        let anchorId = rows[count].id
        let before = visualY(of: anchorId)
        rows.removeFirst(count)
        applySnapshot()
        collectionView.layoutIfNeeded()
        let after = visualY(of: anchorId)
        let delta = (after ?? 0) - (before ?? 0)
        if delta != 0 {
            collectionView.contentOffset.y += delta
            collectionView.layoutIfNeeded()
        }
        let residual = (visualY(of: anchorId) ?? before ?? 0) - (before ?? 0)
        diagnostic("list.insert", ["rows": String(count),
                                   "deltaPt": String(format: "%.0f", delta),
                                   "reason": "drop"])
        settle(anchorId: anchorId, moved: residual)
    }

    // MARK: - 跳转 / 探针用的定位（**不许**用作插入与丢弃的位移手段）

    /// 某一行当前的高度（量不到返回 nil）。spike D 用它比较"回收/水合前后行高是否一致"。
    func rowHeight(of id: String) -> CGFloat? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.collectionViewLayout
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height
    }

    /// 当前是否还有已回收的行（驱动与诊断用）。
    var hasReclaimedRows: Bool { rows.contains { $0.isReclaimed } }

    /// 行在屏幕上的 y（spike D 比较水合前后位置）。
    func screenY(of id: String) -> CGFloat? { visualY(of: id) }

    /// 回收一批行（只换载荷，不动身份与高度）。
    func reclaim(ids: [String]) {
        let freed = rows.filter { ids.contains($0.id) && !$0.isReclaimed }
            .reduce(0) { $0 + $1.payloadBytes }
        for index in rows.indices where ids.contains(rows[index].id) { rows[index].reclaim() }
        applySnapshot()
        diagnostic("list.reclaim", ["rows": String(ids.count),
                                    "bytes": String(freed),
                                    "totalBytes": String(payloadBytes())])
    }

    /// 把记录还回来做水合（真实现里这些记录来自本地库，**0 网络**）。
    func rehydrate(items: [TimelineItem]) {
        let started = CFAbsoluteTimeGetCurrent()
        var rehydrated = 0
        for item in items {
            guard let index = rows.firstIndex(where: { $0.id == item.id }), rows[index].isReclaimed else { continue }
            rows[index].rehydrate(with: item)
            rehydrated += 1
        }
        applySnapshot()
        collectionView.layoutIfNeeded()
        diagnostic("list.rehydrate", [
            "rows": String(rehydrated),
            "ms": String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000),
            "net": "0",
        ])
    }

    /// 上一次滚动上报时读者是不是贴着底。
    private var lastReportedAtBottom = true

    /// 满足"回到底部"的意图。
    ///
    /// 一次 `scrollToItem` 会被在飞的批量更新吞掉（真机反馈"点了仍无效"），所以：
    /// 记意图 + **按 0/120/300/600ms 重试**，每次重试前再确认一次"还没到底"。
    func satisfyBottomIntent() {
        guard wantsBottom, let last = rows.last?.id else { return }
        setOffsetToBottom()
        Task { @MainActor [weak self] in
            for delay in [0, 120, 300, 600, 1000] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard let self, self.wantsBottom else { return }
                if self.bottomDistance() <= Self.bottomSlack { return }
                // 直接改 `contentOffset`，**不用** `scrollToItem`：`apply(snapshot)` 是异步的，
                // 同一轮里 `scrollToItem` 打的是旧数据源的下标，UIKit 会直接忽略
                // （真机反馈"点了仍无效"，探针里也看到 `before == after`）。
                // 自撑高度的列表里内容高度是估算值，所以要按 0/120/300/600/1000ms 多修几次。
                self.setOffsetToBottom()
            }
            _ = last
        }
    }

    /// 视口距底部的距离（点）。
    func bottomDistance() -> CGFloat {
        let content = collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
        return content - collectionView.bounds.height - collectionView.contentOffset.y
    }

    func cancelBottomIntent() { wantsBottom = false }

    /// 视口距内容顶端的距离（点）。
    func distanceToTop() -> CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    /// 驱动用：把视口送到内容顶端（`-DSHProbeOlderScroll` 的 uikit 版）。
    func scrollToTop() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
                                        animated: false)
    }

    /// 钉到底部（打开会话、跟随中、以及"回到底部"按钮）。
    ///
    /// 记成**意图**：`scrollToItem` 一次可能被在飞的批量更新吞掉，所以之后每次布局/更新
    /// 都会再满足一次，直到真的贴到底（或者读者自己滚走）。
    func scrollToBottom() {
        wantsBottom = true
        satisfyBottomIntent()
        guard let last = rows.last?.id else { return }
        // 诊断：按钮点了到底有没有把视口带走（真机反馈过"点了不生效"）。
        // 前后各报一次——只报"调用时"的距离说明不了问题，要看**滚完之后**还剩多远。
        let before = distanceToTop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.diagnostic("list.scrollToBottom", [
                "before": String(format: "%.0f", before),
                "after": String(format: "%.0f", self.distanceToTop()),
                "items": String(self.rows.count),
            ])
        }
    }

    // MARK: - 回收 / 再水合（US3：FR-004/FR-005/SC-004）

    /// 视口内行的下标区间（按布局属性与可见带求交）。
    func visibleRange() -> Range<Int> {
        // 可见带 = 内容坐标里的"当前视口矩形"。不能拿 `bounds` 去 `inset(by:)`——
        // 那是把 inset 加到 origin 上，得到的矩形既不是视口也不是内容区，
        // 于是 `visible=2`（2026-10-08 实测：扫描探针里可见行只有 2 行，回收判定因此全乱）。
        let band = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        var first: Int?
        var last: Int?
        for index in rows.indices {
            guard let attributes = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { continue }
            if attributes.frame.intersects(band) {
                if first == nil { first = index }
                last = index
            }
        }
        guard let first, let last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// "几屏"按**点**算，不按行数。
    ///
    /// 行高差得很远（这个会话里一行能到 1151pt，一屏只放得下 2 行；短会话里一屏十几行），
    /// 所以"离视口 5 屏"只能用点：`5 × 视口高度`。按行数换算会把"5 屏"错算成几十行，
    /// 结果一上来就把远处全回收了（2026-10-08 实测：`visible=2`、`reclaim=7`）。
    private func bandWithMargin(screens: Int) -> CGRect {
        let viewport = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let margin = CGFloat(screens) * viewport.height
        return viewport.insetBy(dx: 0, dy: -margin)
    }

    /// 离视口超过 `screens` 屏、且还没回收的行 —— 可以回收。
    func rowsToReclaim(screens: Int) -> [String] {
        guard !rows.isEmpty, collectionView.bounds.height > 0 else { return [] }
        let band = bandWithMargin(screens: screens)
        var picked: [String] = []
        for index in rows.indices where !rows[index].isReclaimed {
            guard let attributes = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { continue }
            if !attributes.frame.intersects(band) { picked.append(rows[index].id) }
        }
        return picked
    }

    /// 已被回收、但已经回到视口 `screens` 屏以内的行 —— 需要把内容要回来（seq 列表）。
    func reclaimedSeqsNearViewport(screens: Int) -> [Int] {
        guard !rows.isEmpty else { return [] }
        // 用**下标**判近远，不用布局属性：被回收的行往往没被渲染，
        // `layoutAttributesForItem` 对它们返回 nil，于是"近"永远判不出来（2026-10-08 实测 `near=0`）。
        // 下标按"可见行数"换算：可见 n 行 ⇒ 1 屏 ≈ n 行，所以 screens 屏 ≈ screens × max(n, 4) 行。
        let visible = visibleRange()
        guard !visible.isEmpty else { return [] }
        let perScreen = max(visible.count, 4)
        let span = screens * perScreen
        let lower = max(0, visible.lowerBound - span)
        let upper = min(rows.count, visible.upperBound + span)
        var seqs: [Int] = []
        for index in rows.indices {
            guard case .reclaimed(let seq, _, _) = rows[index].state else { continue }
            if index >= lower, index < upper { seqs.append(seq) }
        }
        return seqs
    }

    /// 契约里的两个距离（spec 008 的 clarify 决定：5 屏回收 / 2 屏水合）。
    /// 真值口径在 `contracts/list-host.md` §4；这里读探针覆盖，缺省就是契约值。
    static var reclaimDistanceScreens: Int { ProbeVariants.reclaimScreens }
    static var rehydrateDistanceScreens: Int { ProbeVariants.rehydrateScreens }

    func scrollTo(id: String, animated: Bool = false) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0),
                                    at: .centeredVertically, animated: animated)
    }

    /// 记录"锚点位移"，用例据此判定（≤8pt 为 `ok=1`）。
    func settle(anchorId: String, moved: CGFloat) {
        lastSettle = (moved, abs(moved) <= Self.tolerance)
        diagnostic("list.settle", ["moved": String(format: "%.0f", moved),
                                   "ok": lastSettle?.ok == true ? "1" : "0",
                                   "anchor": anchorId])
    }

    var currentAnchorId: String? { rows.first?.id }

    /// 屏幕大约能放几行（按行高 ~44pt 估）。保留带用它换算，保证丢弃后仍填得满屏幕。
    var visibleRowEstimate: Int {
        let height = collectionView.bounds.height
        guard height > 0 else { return 8 }
        return max(8, Int(height / 44))
    }

    // MARK: - 内部

    static let tolerance: CGFloat = 8

    private func item(for id: String) -> TimelineItem? {
        rows.first { $0.id == id }?.item
    }

    private func payloadBytes() -> Int {
        rows.reduce(0) { $0 + $1.payloadBytes }
    }

    private func applySnapshot(reloading reloadIds: Set<String> = []) {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections([TranscriptListSection.main])
        // 防御：diffable 对重复 identifier 会**直接断言打死 App**。身份稳定是本设计的承诺，
        // 真出现重复说明调用方拼错了数据——那就去重并留一条诊断，不许把 App 带走。
        var seen = Set<String>()
        let identifiers = rows.map(\.id).filter { seen.insert($0).inserted }
        if identifiers.count != rows.count {
            diagnostic("list.duplicate", ["rows": String(rows.count),
                                          "unique": String(identifiers.count)])
            rows = rows.filter { seen.contains($0.id) }
        }
        snapshot.appendItems(identifiers, toSection: TranscriptListSection.main)
        // 身份不变但内容变了的行（流式增长、缺口三态、pending→sent）要 reload
        // 才会重配 cell；同一事务里完成，不拆第二次提交。
        let reloadable = reloadIds.intersection(identifiers)
        if !reloadable.isEmpty { snapshot.reloadItems(Array(reloadable)) }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// 某一行在**屏幕上**的 y（内容坐标 − 当前 offset）；量不到返回 nil。
    private func visualY(of id: String?) -> CGFloat? {
        guard let id, let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let path = IndexPath(item: index, section: 0)
        guard let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(at: path) else {
            return nil
        }
        return attributes.frame.minY - collectionView.contentOffset.y
    }

    private func diagnostic(_ name: String, _ fields: [String: String]) {
        onDiagnostic?(name, fields)
    }
}

extension TranscriptListHost {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distance = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        onScroll?(distance)
        scheduleReclaimCheck()
        // 视口距底部的距离：这是"读者还在不在最新那一头"的唯一依据
        // （真机反馈过"刷新时偶尔自己跳到底部"——用拖动位移判定跟随是不可靠的）。
        let atBottom = bottomDistance() <= Self.bottomSlack
        lastReportedAtBottom = atBottom
        onBottomChanged?(atBottom)
        // **可见余量预取**：离顶端还有一屏半就开始要，而不是等贴到顶（真机反馈"预取太慢"）。
        // 贴着顶时也允许继续要 —— 读者一直往上拉就一页页接着给。
        if distance < prefetchMargin() {
            if nearTopArmed {
                nearTopArmed = false
                onNearTop?()
            }
        } else if distance > prefetchMargin() * 2 {
            nearTopArmed = true
        }
    }
}

extension TranscriptListHost {

    /// 滚动里顺手做一次回收/水合判定，但**延后 400ms 且合并**：不与滚动抢主线程。
    func scheduleReclaimCheck() {
        guard reclaimCheckTask == nil else { return }
        reclaimCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.reclaimCheckTask = nil
            guard let self, self.window != nil else { return }
            let reclaim = self.rowsToReclaim(screens: Self.reclaimDistanceScreens)
            if !reclaim.isEmpty { self.onReclaim?(reclaim) }
            let seqs = self.reclaimedSeqsNearViewport(screens: Self.rehydrateDistanceScreens)
            // 扫描探针：`reclaimed` 是当前已回收的行数，`near` 是"回到视口附近、该水合"的条数。
            // `list.rehydrate` 没出现时，看这两个数就知道是"没判定出来"还是"判出来了但取不到"。
            self.diagnostic("list.reclaim.scan", [
                "reclaimed": String(self.rows.filter(\.isReclaimed).count),
                "near": String(seqs.count),
                "visible": String(self.visibleRange().count),
                "reclaim": String(reclaim.count),
            ])
            if !seqs.isEmpty { self.onNeedRehydrate?(seqs) }
        }
    }
}
