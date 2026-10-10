import DSHKit
import Foundation

/// T025：「我问过的」读本地 MessageStore（user_inputs 表 + FTS5 trigram），零网络。
///
/// 数据来自 T024 的冷启动灌库；本地还没有灌过（老库、灌库被跳过）时返回空数组，
/// 由面板回退到原来的网络路径——本地路径只是加速与离线可用，不是唯一来源。
extension ChatModel {

    /// 本会话的「我问过的」本地命中（按 seq 由近及远）。`query` 为空是浏览模式
    /// （全量列表），非空走 FTS5（<3 字符由 store 降级 LIKE）。返回 nil 表示
    /// 本地层不可用（磁盘层缺位 / 会话未挂），调用方应直接走网络路径。
    func localUserInputHits(query: String) async -> [TranscriptSearchHit]? {
        guard let store = messageLayer?.store,
              let scope = sessionScope,
              let sessionId = session?.sessionId
        else { return nil }
        let rows: [MessageStore.UserInputRow]
        do {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            rows = needle.isEmpty
                ? try await store.userInputs(scope: scope)
                : try await store.searchUserInputs(scope: scope, query: needle)
        } catch {
            return nil
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { $0.sessionId == sessionId }
            .sorted { $0.seq > $1.seq }
            .map { row in
                let range = Self.highlightRange(of: needle, in: row.snippet)
                // 合成身份（同连接器路径的窗口外命中）：行身份由 seq 承担，点中后
                // ChatView.jumpToHit 按 seq 走 .jump 区间判定水合上下文。
                return TranscriptSearchHit(
                    id: "seq-\(row.seq)", role: .me, snippet: row.snippet,
                    highlightStart: range?.0 ?? 0, highlightLength: range?.1 ?? 0,
                    seq: row.seq)
            }
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
