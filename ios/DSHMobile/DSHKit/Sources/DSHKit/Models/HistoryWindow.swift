import Foundation

/// One request for an exact backward window, answered by the **connector**
/// (spec 007, `_link/sessionWindow`).
///
/// Unlike the Host's own `session/page`, the connector's method takes the
/// position it should end before and nothing else: no `throughSeq`, no guessing
/// whether a number means a seq or a log offset. `before` is exclusive — the page
/// must end at `before - 1`, which is how the phone knows a page abuts the window
/// it already holds.
///
/// Args are flat (`{address, before, …}`), matching the connector's other local
/// methods (`_link/git*`); the Host's `{request: …}` envelope is for Host
/// endpoints only.
public struct HistoryWindowRequest: Sendable, Codable {
    public let address: SessionAddress
    /// Exclusive upper bound: the oldest seq the phone already holds.
    public let before: Int
    /// Optional hard ceiling (the follow snapshot's cursor).
    public let through: Int?
    /// How many records the phone would like.
    public let limit: Int?
    /// Byte budget for the page; the connector trims the oldest end to fit.
    public let maxBytes: Int?
    /// Optional role filter (`["me"]`…), connector capability `history-role-filter`
    /// (spec 009 T031/T033). Filtering affects only which records come back;
    /// the `before` cursor semantics are unchanged.
    public let roles: [String]?

    public init(address: SessionAddress, before: Int, through: Int? = nil,
                limit: Int? = nil, maxBytes: Int? = nil, roles: [String]? = nil) {
        self.address = address
        self.before = before
        self.through = through
        self.limit = limit
        self.maxBytes = maxBytes
        self.roles = roles
    }
}

/// What the connector hands back.
public struct HistoryWindowValue: Sendable, Codable {
    public let records: [SessionRecord]
    public let startSeq: Int?
    public let endSeq: Int?
    /// Host-authoritative "there is older history".
    public let hasMore: Bool
    /// Which budget cut the page: `count`, `bytes`, or nothing.
    public let truncatedBy: String?
    /// The requested position no longer exists (the session was trimmed), so this
    /// page starts from the log's newest event. The phone must treat a page that
    /// does not abut its window as "the log got shorter" rather than as a hole.
    public let clamped: Bool?

    public init(records: [SessionRecord], startSeq: Int?, endSeq: Int?, hasMore: Bool,
                truncatedBy: String? = nil, clamped: Bool? = nil) {
        self.records = records
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.hasMore = hasMore
        self.truncatedBy = truncatedBy
        self.clamped = clamped
    }

    /// The page as the pager wants it.
    public func page() -> TranscriptPager.Page {
        TranscriptPager.Page(
            records: records,
            startSeq: startSeq ?? records.first?.event.seq ?? 0,
            endSeq: endSeq ?? records.last?.event.seq ?? 0,
            hasMore: hasMore,
            clamped: clamped ?? false
        )
    }
}
