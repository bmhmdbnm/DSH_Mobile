import Foundation

/// One request for in-session search, answered by the **connector**
/// (`_link/sessionFind`, spec 007 FR-010…FR-012).
///
/// Flat args, like every `_link/*` method: the Host's `{request: …}` envelope is
/// for Host endpoints only.
public struct HistorySearchRequest: Sendable, Codable {
    public let address: SessionAddress
    public let query: String
    /// Which roles to keep: `me` / `agent` / `tool`. Omitted means all three.
    public let roles: [String]?
    public let limit: Int?
    /// Opaque continuation from the previous page.
    public let cursor: String?
    /// Advanced: how many seqs one scan chunk covers (bounded by the connector).
    public let chunk: Int?

    public init(address: SessionAddress, query: String, roles: [String]? = nil,
                limit: Int? = nil, cursor: String? = nil, chunk: Int? = nil) {
        self.address = address
        self.query = query
        self.roles = roles
        self.limit = limit
        self.cursor = cursor
        self.chunk = chunk
    }
}

/// One hit: where it is, what role it has, and the snippet to show.
public struct HistorySearchHit: Sendable, Codable {
    public let seq: Int
    public let role: String
    public let snippet: String
    public let highlightStart: Int
    public let highlightLength: Int

    public init(seq: Int, role: String, snippet: String, highlightStart: Int, highlightLength: Int) {
        self.seq = seq
        self.role = role
        self.snippet = snippet
        self.highlightStart = highlightStart
        self.highlightLength = highlightLength
    }
}

public struct HistorySearchValue: Sendable, Codable {
    public let hits: [HistorySearchHit]
    public let cursor: String?
    public let hasMore: Bool
    /// `index` when the deployment's full-text index answered, `scan` otherwise.
    public let source: String?

    public init(hits: [HistorySearchHit], cursor: String?, hasMore: Bool, source: String? = nil) {
        self.hits = hits
        self.cursor = cursor
        self.hasMore = hasMore
        self.source = source
    }
}

/// Where a hit lands in the transcript the reader is looking at.
///
/// A hit carries a journal `seq`; the transcript is a list of *rows*, and a row
/// owns the seq that produced it (an assistant row can be produced by a seq well
/// below a later tool result that belongs to it). The row a hit belongs to is
/// therefore the last row whose own seq is at or below the hit's; if the hit
/// precedes everything loaded, the first row is the closest thing to it.
public enum TranscriptHitLocator {
    public static func row(forSeq seq: Int, in items: [TimelineItem]) -> TimelineItem? {
        guard !items.isEmpty else { return nil }
        var candidate: TimelineItem?
        for item in items {
            if item.seq <= seq { candidate = item } else { break }
        }
        return candidate ?? items.first
    }

    /// Fills the phone-side row id on each hit, dropping the ones that have no row
    /// to point at (the reader has not loaded that stretch yet).
    public static func attach(hits: [HistorySearchHit], to items: [TimelineItem]) -> [TranscriptSearchHit] {
        // 同一条记录可能落进同一行（命中映射是按 seq → 行），去重后每行只留一条：
        // 列表用行 id 当身份，重复 id 会让 SwiftUI 的 `ForEach` 出现未定义渲染（少行/错行）。
        var seen = Set<String>()
        let windowOldest = items.first?.seq ?? Int.max
        return hits.compactMap { hit in
            let role: TranscriptSearchHit.Role = switch hit.role {
            case "me": .me
            case "tool": .tool
            default: .agent
            }
            // 命中在**已加载窗口之外**（浏览"我的提问"时几乎全是这样）：`row(forSeq:)` 会退化成
            // "窗口第一行"，全都会被去重成一条——那正是"列表里只剩几条"的原因。
            // 这类命中用合成身份（`seq-<n>`）：列表直接显示连接器给的 snippet，
            // 点它时由 `ChatView.jumpToHit` 按 seq 换窗口再跳（那条路已经验过）。
            if hit.seq < windowOldest {
                let synthetic = "seq-\(hit.seq)"
                guard seen.insert(synthetic).inserted else { return nil }
                return TranscriptSearchHit(id: synthetic, role: role, snippet: hit.snippet,
                                           highlightStart: hit.highlightStart,
                                           highlightLength: hit.highlightLength, seq: hit.seq)
            }
            guard let row = row(forSeq: hit.seq, in: items) else { return nil }
            guard seen.insert(row.id).inserted else { return nil }
            return TranscriptSearchHit(id: row.id, role: role, snippet: hit.snippet,
                                       highlightStart: hit.highlightStart,
                                       highlightLength: hit.highlightLength, seq: hit.seq)
        }
    }
}
