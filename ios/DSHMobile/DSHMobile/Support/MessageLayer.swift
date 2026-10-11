import DSHKit
import Foundation

/// App 侧 009 消息层宿主（tasks T010–T012，spec 009「冷启动流程」）。
///
/// 持有进程级唯一的 `MessageStore`（GRDB 磁盘层）与 `MessagePipeline`（内存层枢纽），
/// 列表冷启动叠加、预取瀑布、进会话首帧都从这一个实例取数。网络面（按页拉取）
/// 通过注入的 client 闭包现取，重连换了 carrier 不用重建管道。
@MainActor
final class MessageLayer {

    /// 拉取/发送失败原因。预取路径对失败一律静默（磁盘只是缓存，取用失败即拉取
    /// 兜底），这里只为让调试日志可读。
    enum FetchFailure: Error {
        /// 链接未建立：预取整体跳过，不刷日志（tasks T011 的硬要求）。
        case notConnected
        /// 该会话没有注册过拉取地址（不在当前列表里）。
        case noAddress
    }

    /// 会话 id → 拉取地址。subagent 会话的地址需要父 id 与 mode，只能从列表行的
    /// `SessionSummary` 推导，所以由列表/会话侧注册。`@Sendable` 的 fetch 闭包不能
    /// 挂 MainActor，地址簿自带锁。
    final class AddressBook: @unchecked Sendable {
        private var table: [String: SessionAddress] = [:]
        private let lock = NSLock()

        func register(_ summaries: [SessionSummary]) {
            lock.lock()
            defer { lock.unlock() }
            for summary in summaries {
                table[summary.sessionId] = summary.address
            }
        }

        func address(for sessionId: String) -> SessionAddress? {
            lock.lock()
            defer { lock.unlock() }
            return table[sessionId]
        }
    }

    let addresses = AddressBook()
    private(set) var store: MessageStore?
    private(set) var pipeline: MessagePipeline?
    /// attach 时注入的 client 现取闭包，T024 灌库也要用（重连后自动换 carrier）。
    private var clientProvider: (@Sendable () -> DSHClient?)?
    /// DEBUG 故障注入：前 N 次取页失败（`-DSHProbeFailPage <n>`）。release 恒 0。
    private let pageFailures = PageFailureInjector(remaining: ProbeVariants.failPageAttempts)

    /// 注册一批会话的拉取地址（列表刷新后、进会话前各喂一次）。
    func registerAddresses(_ summaries: [SessionSummary]) {
        addresses.register(summaries)
    }

    /// 懒建磁盘层与内存层（各一次，进程级复用）。`client` 每次调用现取：
    /// 未连接时 fetch 抛 `notConnected`，预取方按"跳过"处理。
    func attach(client: @escaping @Sendable () -> DSHClient?) {
        clientProvider = client
        if store == nil {
            // 磁盘层建不起来（如存储被拒）时整套 009 叠加自动缺位，
            // 列表/会话都回退到现有行为——不劣于现状。
            store = try? MessageStore()
        }
        guard let store, pipeline == nil else { return }
        let addresses = self.addresses
        // T028：`-DSHProbeFailPage` 重接到 009 链路——包在 PageFetch 外层，
        // 前 N 次取页直接抛错，驱动慢闸场景③（断网缺口失败重试）。
        let pageFailures = self.pageFailures
        // T026：热窗口按 spec 裁决的 500 条裁剪（US2 期间为避免淘汰后回看
        // 静默丢行临时放宽到 5000；空白带根因——磁盘水合不发 diff——已在
        // SessionPipeline 修复，这里调回预算值）。
        pipeline = MessagePipeline(
            store: store,
            fetchFactory: { ref in
                { range, priority in
                    // 只对用户驱动的取页注入失败：预取/冷启动吃配额会让慢闸
                    // 场景③永远等不到可见失败（007 的 PageFailureInjector 头注）。
                    // failPageArmed：带 -DSHProbeFailPageOnDrive 时再等驱动开始，
                    // 打开阶段的可见取页按竞争拿优先级，会随机吃掉配额（用例 48）。
                    if priority == .userVisible, ProbeVariants.failPageArmed,
                       pageFailures.shouldFail() {
                        throw PageFailureInjected()
                    }
                    guard let client = client() else { throw FetchFailure.notConnected }
                    guard let address = addresses.address(for: ref.sessionId) else {
                        throw FetchFailure.noAddress
                    }
                    // `before` 是开区间上界：页必须结束在 before-1，正好盖住 range。
                    let value = try await client.historyWindow(HistoryWindowRequest(
                        address: address, before: range.upperBound + 1, through: nil,
                        limit: range.count, maxBytes: 256 * 1024))
                    return SessionPipeline.FetchPage(
                        records: value.records, hasMore: value.hasMore,
                        clamped: value.clamped ?? false)
                }
            },
            // T022 上行：requestId 就是管道给的 clientId（同一套稳定 UUID，
            // 不并存第二套身份）——host 把它落在 durable 消息的 source.rpcId 上，
            // 确认走下行回流（follow → SessionPipeline → rpcId 命中原地替换），
            // 所以这里受理即返回 nil，不伪造回包。附件发送不走这里（见 ChatModel）。
            sender: { ref, text, clientId, steer in
                guard let client = client() else { throw FetchFailure.notConnected }
                try await client.prompt(SessionPromptRequest(
                    requestId: clientId.uuidString,
                    sessionId: ref.sessionId,
                    mode: steer ? .steer : .queue,
                    content: [.text(text)]))
                return nil
            },
            // T022 重发去重：崩溃前可能确认了没落库。重发前按 clientId 对服务端
            // 最新页查一次（before=.max 即最新），已有则只替换不重发。
            confirmationLookup: { ref, clientId in
                guard let client = client(),
                      let address = addresses.address(for: ref.sessionId) else { return nil }
                let value = try? await client.historyWindow(HistoryWindowRequest(
                    address: address, before: .max, limit: 50, maxBytes: 256 * 1024))
                return value?.records.first { record in
                    guard case .userMessage(let message) = ChatEventDecoder.decode(record.event)
                    else { return false }
                    return message.isFromHuman && message.rpcId == clientId.uuidString
                }
            },
            hotLimit: 500
        )
    }

    // MARK: - T033 用户输入灌库（三表终局，spec 009 data-model v3）

    /// 冷启动预取瀑布之后的低优先级任务：逐会话走 `_link/sessionWindow` 的
    /// `roles:['me']` 过滤分页，把**完整记录**灌进 `record` 表（与浏览落库同一
    /// 幂等路径，不再写独立摘要表）。
    ///
    /// 连接器没有 `history-role-filter` 能力时整体跳过（降级回浏览模式会拿到
    /// 没有 source 的摘要，写进 record 就是脏数据——宁可不灌，等连接器升级）。
    /// 刻意**串行**：灌库是缓存行为，不许和读者正在用的拉取抢隧道（连接器对
    /// 同会话并发窗口读也直接回 `link/busy`）。未连接、磁盘层缺位、地址未注册
    /// 都静默跳过；去重与增量判定全在 `UserInputBackfiller`。
    func backfillUserInputs(scope: String, summaries: [SessionSummary],
                            roleFilterSupported: Bool) async {
        guard let store, let client = clientProvider?() else { return }
        guard roleFilterSupported else {
            ViewportProbe.note("userinputs.backfill.degraded", [
                "reason": "connector-missing-history-role-filter",
            ], force: true)
            return
        }
        let backfiller = UserInputBackfiller(store: store)
        for summary in summaries {
            guard let address = addresses.address(for: summary.sessionId) else { continue }
            let lastSeq = summary.asOfSeq
            guard lastSeq > 0 else { continue }
            do {
                let outcome = try await backfiller.backfill(
                    scope: scope, sessionId: summary.sessionId, lastSeq: lastSeq) { before in
                        try await client.historyWindow(HistoryWindowRequest(
                            address: address, before: before ?? .max,
                            limit: 200, maxBytes: 256 * 1024, roles: ["me"]))
                    }
                if case .pulled(let pages, let rows) = outcome {
                    ViewportProbe.note("userinputs.backfill", [
                        "session": summary.sessionId,
                        "pages": String(pages), "rows": String(rows),
                    ], force: true)
                }
            } catch {
                // 失败不记账（backfiller 语义），下次冷启动重试；静默，不刷错误。
                continue
            }
        }
    }
}
