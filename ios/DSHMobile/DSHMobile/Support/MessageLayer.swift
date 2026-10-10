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
        /// 上行发送还没接进 009 管道（现有发送路径不变，见 ChatModel）。
        case sendUnsupported
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

    /// 注册一批会话的拉取地址（列表刷新后、进会话前各喂一次）。
    func registerAddresses(_ summaries: [SessionSummary]) {
        addresses.register(summaries)
    }

    /// 懒建磁盘层与内存层（各一次，进程级复用）。`client` 每次调用现取：
    /// 未连接时 fetch 抛 `notConnected`，预取方按"跳过"处理。
    func attach(client: @escaping @Sendable () -> DSHClient?) {
        if store == nil {
            // 磁盘层建不起来（如存储被拒）时整套 009 叠加自动缺位，
            // 列表/会话都回退到现有行为——不劣于现状。
            store = try? MessageStore()
        }
        guard let store, pipeline == nil else { return }
        let addresses = self.addresses
        pipeline = MessagePipeline(
            store: store,
            fetchFactory: { ref in
                { range in
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
            sender: { _, _, _ in throw FetchFailure.sendUnsupported }
        )
    }
}
