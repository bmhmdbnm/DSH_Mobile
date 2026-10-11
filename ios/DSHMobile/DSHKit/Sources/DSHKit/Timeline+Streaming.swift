import Foundation

/// ChatTimeline 的流式半边（spec 009 tasks T020；文件按职责拆分，沿用
/// `MessageStore+Records` / `SessionPipeline+Streaming` 先例）。
///
/// 管道模式下流式增量经 SessionPipeline 的 frameTick 合并后以 provisional
/// 记录（带 stream 标记）进快照；桥把「只有流式行文本变长」的 diff 映射为
/// 这里的单行增量更新，而不是整树重折（流式高频 diff 下重折是主开销）。
extension ChatTimeline {

    /// 流式单行增量更新：只改写某 seq 的 provisional 行文本/思考，不动其它行。
    /// 返回 false = 目标行不在窗口里（尚未折入或结构已变），调用方回退整树重折。
    ///
    /// 思考先行、正文后到的流式里，provisional 记录折叠时正文块为空被跳过
    /// （`ChatTimeline` 对空块不产行），时间线只有 reasoning 行。正文开始增长后，
    /// 若只凭「改到了 reasoning 行」就报成功，正文行永远插不进来——画面冻结
    /// （慢闸场景⑤ run 20261011-105530：11.2s 起 34 秒帧冻结在 66pt 思考行）。
    /// 所以「内容该有对应行却没有」时必须返回 false：行插入只有整树重折能做。
    @discardableResult
    public mutating func applyStreamingUpdate(seq: Int, text: String, reasoning: String) -> Bool {
        var touched = false
        var hasTextRow = false
        var hasReasoningRow = false
        for index in items.indices where items[index].isStreaming && items[index].seq == seq {
            switch items[index].kind {
            case .assistantText:
                items[index].kind = .assistantText(text: text)
                hasTextRow = true
                touched = true
            case .reasoning:
                items[index].kind = .reasoning(text: reasoning)
                hasReasoningRow = true
                touched = true
            default:
                break
            }
        }
        guard touched else { return false }
        // 与折叠同一个「空块不产行」口径（trim 后为空才算没有内容）：
        // 有内容却没有对应行 = 原地更新无处可写，回退整树重折把行插进来。
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasTextRow { return false }
        if !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasReasoningRow {
            return false
        }
        return true
    }
}
