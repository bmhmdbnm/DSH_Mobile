import DSHKit
import Foundation

/// T034：「我问过的」读本地 MessageStore 的 `record` 表（三表终局）——浏览走
/// `userInputRecords`（role='me' 且来源是用户本人），关键词走 `record_fts`
///（trigram，<3 字符由 store 降级 LIKE），全程零网络。
///
/// 数据来自 T033 的冷启动灌库；本地还没有灌过（老库、连接器不支持
/// `history-role-filter` 被跳过）时返回空数组，由面板回退到原来的网络路径——
/// 本地路径只是加速与离线可用，不是唯一来源。
extension ChatModel {

    /// 本会话的「我问过的」本地命中（按 seq 由近及远）。`query` 为空是浏览模式
    /// （全量列表），非空走 FTS5。返回 nil 表示本地层不可用（磁盘层缺位 /
    /// 会话未挂），调用方应直接走网络路径。
    func localUserInputHits(query: String) async -> [TranscriptSearchHit]? {
        guard let store = messageLayer?.store,
              let scope = sessionScope,
              let sessionId = session?.sessionId
        else { return nil }
        // 完整性闸门（data-model v3）：灌库串行进行期间本地只有最新窗口的几条，
        // 拿它当全量会显示不全还谎报「已经读到最开头」（T036 慢闸抓出）。
        // 未灌全回退连接器路径（能翻页拿全量），灌全后才走本地零网络。
        guard (try? await store.userInputsSyncedAt(scope: scope, sessionId: sessionId)) != nil
        else { return nil }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [MessageStore.UserInputEntry]
        do {
            entries = needle.isEmpty
                ? try await store.userInputRecords(scope: scope)
                : try await store.searchUserInputRecords(scope: scope, query: needle)
        } catch {
            return nil
        }
        return entries.filter { $0.sessionId == sessionId }
            .sorted { $0.record.event.seq > $1.record.event.seq }
            .compactMap { entry in
                let record = entry.record
                guard let snippet = Self.snippet(of: record), !snippet.isEmpty else { return nil }
                let range = Self.highlightRange(of: needle, in: snippet)
                // 合成身份（同连接器路径的窗口外命中）：行身份由 seq 承担，点中后
                // ChatView.jumpToHit 按 seq 走 .jump 区间判定水合上下文。
                return TranscriptSearchHit(
                    id: "seq-\(record.event.seq)", role: .me, snippet: snippet,
                    highlightStart: range?.0 ?? 0, highlightLength: range?.1 ?? 0,
                    seq: record.event.seq)
            }
    }

    /// 记录正文：data.text 优先，blocks 拼接兜底（与 MessageStore.snippet 同一约定）。
    /// 真实 user/message 的正文在 `data.content[]`（blocks 形态）——读错键会让
    /// 本地列表整列丢光只剩 live 尾巴的几条（T036 慢闸抓出）。
    private static func snippet(of record: SessionRecord) -> String? {
        let data = record.event.data
        if let text = data["text"]?.stringValue, !text.isEmpty {
            return String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
        }
        if let blocks = data["content"]?.arrayValue ?? data["blocks"]?.arrayValue {
            let joined = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
            if !joined.isEmpty {
                return String(joined.replacingOccurrences(of: "\n", with: " ").prefix(120))
            }
        }
        return nil
    }

    /// 关键词在片段里的首个大小写不敏感命中（字符偏移，同 TranscriptSearch 的约定）。
    private static func highlightRange(of needle: String, in snippet: String) -> (Int, Int)? {
        guard !needle.isEmpty,
              let range = snippet.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        return (snippet.distance(from: snippet.startIndex, to: range.lowerBound),
                snippet.distance(from: range.lowerBound, to: range.upperBound))
    }
}
