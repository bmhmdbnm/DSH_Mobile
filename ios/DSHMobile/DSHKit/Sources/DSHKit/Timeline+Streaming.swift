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
    @discardableResult
    public mutating func applyStreamingUpdate(seq: Int, text: String, reasoning: String) -> Bool {
        var found = false
        for index in items.indices where items[index].isStreaming && items[index].seq == seq {
            switch items[index].kind {
            case .assistantText:
                items[index].kind = .assistantText(text: text)
                found = true
            case .reasoning:
                items[index].kind = .reasoning(text: reasoning)
                found = true
            default:
                break
            }
        }
        return found
    }
}
