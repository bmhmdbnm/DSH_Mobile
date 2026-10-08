import Foundation

/// `TimelineItem` ↔ diffable data source 的 item identifier。
///
/// 身份规则**必须与 007 一致**（`TimelineItem.id`）：折叠/展开、工具卡配对、搜索高亮、
/// 跳转都靠它认行。新宿主只换"怎么更新列表"，不换"行是谁"。
public enum TranscriptListSection {

    /// 一段就够：转写是一条时间线，不需要多 section。
    public static let main = "transcript"

    /// 行的稳定标识（直接用 007 的 `TimelineItem.id`，不做任何重新编码）。
    public static func identifier(for item: TimelineItem) -> String { item.id }

    /// 把一批行按 seq 排好（补页/换窗口之后顺序可能被打乱）。
    public static func ordered(_ items: [TimelineItem]) -> [TimelineItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.seq != rhs.element.seq { return lhs.element.seq < rhs.element.seq }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 判断是不是"往上插了一页"：新一批的最老一条比当前最老一条还老。
    public static func isPrepend(_ incoming: [TimelineItem], current: [TimelineItem]) -> Bool {
        guard let incomingOldest = incoming.first?.seq, let currentOldest = current.first?.seq else {
            return !incoming.isEmpty
        }
        return incomingOldest < currentOldest
    }
}
