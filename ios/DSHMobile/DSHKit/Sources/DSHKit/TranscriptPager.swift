import Foundation

/// The one place that knows where a session's loaded window starts and whether
/// older history exists (spec 007 FR-005/FR-038).
///
/// Replaces four fields that used to live in `ChatModel` (`oldestSeq`,
/// `hasOlder`, `searchOldestSeq`, `searchHasOlder`) and the two independent
/// paging paths they drove. The rule this type exists to enforce is the one the
/// phone kept getting wrong: **a failed page is not the end of the log**. The
/// old code wrote `hasOlder = false` on any error, and the transcript could
/// never offer older history again for that session.
///
/// It is `@MainActor` because every caller is: the transcript's scroll, its
/// prefetch and its retry button are all UI events, and the view reads this state
/// while building a body. `loadOlder` still awaits the network; the `inFlight`
/// guard is set *before* that await, so a second request cannot slip in behind it.
@MainActor
public final class TranscriptPager {

    /// Three states, not a boolean (FR-038). `failed` is explicitly not `end`.
    public enum State: Equatable, Sendable {
        case more
        case end
        case failed(Failure)
    }

    /// Why the last page failed, and whether trying again could work.
    public struct Failure: Equatable, Sendable {
        public let reason: String
        public let retryable: Bool
        public let at: Date
    }

    /// One page as the transport hands it back. `startSeq`/`endSeq` come from the
    /// connector, so contiguity is checked against a fact rather than guessed.
    public struct Page: Sendable {
        public let records: [SessionRecord]
        public let startSeq: Int
        public let endSeq: Int
        public let hasMore: Bool
        /// The connector had to clamp the request to the log's newest event
        /// because the session was trimmed. Only then may a page end above the
        /// window without being treated as a hole (FR-002/FR-041).
        public let clamped: Bool

        public init(records: [SessionRecord], startSeq: Int, endSeq: Int,
                    hasMore: Bool, clamped: Bool = false) {
            self.records = records
            self.startSeq = startSeq
            self.endSeq = endSeq
            self.hasMore = hasMore
            self.clamped = clamped
        }
    }

    /// What one `loadOlder()` did, for the caller and for the diagnostics.
    public enum Outcome: Equatable, Sendable {
        /// Older records arrived (possibly zero *new* rows when every record was
        /// already known — the window still moved, FR-037).
        case prepended(count: Int, oldestSeq: Int?)
        case endOfLog
        case failed(String)
        /// A request was already in flight.
        case busy
    }

    /// Fetches the page strictly older than `before` (exclusive).
    ///
    /// Not `@Sendable`: this type is main-actor state, so its callers are too, and
    /// the closure they hand in belongs to that isolation (it reads the app's
    /// connection and diagnostics).
    public typealias Fetch = (_ before: Int) async throws -> Page

    public enum Diagnostic: Equatable, Sendable {
        case page(requested: Int, startSeq: Int, endSeq: Int, returned: Int,
                  prepended: Int, attempts: Int, hasMore: Bool)
        case failed(requested: Int, reason: String, attempts: Int)
        case nonContiguous(requested: Int, startSeq: Int, endSeq: Int, reason: String)
    }

    private let sessionId: String
    private let pageSize: Int
    private let maxAttempts: Int
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async -> Void
    private let onDiagnostic: (@Sendable (Diagnostic) -> Void)?
    private let now: @Sendable () -> Date

    private var oldest: Int?
    private var newest: Int?
    private var state: State = .more
    private var inFlight = false
    private var attempts = 0
    private var last: Page?

    public init(
        sessionId: String,
        oldestLoadedSeq: Int? = nil,
        newestLoadedSeq: Int? = nil,
        hasMore: Bool = true,
        pageSize: Int = 60,
        maxAttempts: Int = 3,
        retryDelays: [Duration] = [.milliseconds(250), .milliseconds(750)],
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onDiagnostic: (@Sendable (Diagnostic) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionId = sessionId
        self.oldest = oldestLoadedSeq
        self.newest = newestLoadedSeq
        self.pageSize = pageSize
        self.maxAttempts = maxAttempts
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.onDiagnostic = onDiagnostic
        self.now = now
        self.state = hasMore ? .more : .end
    }

    public var currentState: State { state }
    public var oldestLoadedSeq: Int? { oldest }
    public var newestLoadedSeq: Int? { newest }
    /// True while a page is being fetched (the view shows a spinner).
    public var isLoading: Bool { inFlight }
    /// The page that was applied last, so the caller that has to *render* it can
    /// take the records without the pager having to hand them back through the
    /// outcome (and without a second copy of the window bookkeeping).
    public var lastPage: Page? { last }

    /// Merges what a follow snapshot says about the window (the Host's word for
    /// `hasMore` is final) without disturbing a request that is already in flight.
    public func observe(oldestSeq: Int?, newestSeq: Int?, hasMore: Bool) {
        oldest = [oldest, oldestSeq].compactMap { $0 }.min()
        newest = [newest, newestSeq].compactMap { $0 }.max()
        state = hasMore ? .more : .end
    }

    /// Seeds the window from a follow snapshot or a restored cache.
    ///
    /// The Host's word is final for "is there more": a snapshot that says
    /// `hasMore == false` means the window already reaches the start of the log.
    public func reset(oldestLoadedSeq: Int?, newestLoadedSeq: Int?, hasMore: Bool) {
        oldest = oldestLoadedSeq
        newest = newestLoadedSeq
        state = hasMore ? .more : .end
        inFlight = false
        attempts = 0
    }

    /// Loads one page, retrying transport failures (FR-004).
    ///
    /// Retries are for *transport* trouble. A page that arrives non-contiguous is
    /// retried too — that is the case the old code "fixed" by guessing an offset,
    /// and the case where guessing hid a missing stretch of history.
    @discardableResult
    public func loadOlder(_ fetch: Fetch) async -> Outcome {
        guard !inFlight else { return .busy }
        if case .end = state { return .endOfLog }
        guard let before = oldest, before > 0 else {
            state = .end
            return .endOfLog
        }
        inFlight = true
        attempts = 0
        defer { inFlight = false }

        var lastReason = "unknown"
        while attempts < maxAttempts {
            let attempt = attempts + 1
            do {
                let page = try await fetch(before)
                if let violation = contiguityViolation(page, requested: before) {
                    lastReason = violation
                    onDiagnostic?(.nonContiguous(requested: before, startSeq: page.startSeq,
                                                 endSeq: page.endSeq, reason: violation))
                    throw PagerError.nonContiguous(violation)
                }
                attempts = attempt
                return apply(page, requested: before, attempts: attempt)
            } catch {
                lastReason = (error as? PagerError)?.description ?? "\(error)"
                attempts = attempt
                guard attempt < maxAttempts else { break }
                let delay = retryDelays[min(attempt - 1, retryDelays.count - 1)]
                await sleep(delay)
            }
        }
        let failure = Failure(reason: lastReason, retryable: true, at: now())
        state = .failed(failure)
        onDiagnostic?(.failed(requested: before, reason: lastReason, attempts: attempts))
        return .failed(lastReason)
    }

    /// A page must abut the window it extends: it has to end exactly one below
    /// the seq we asked to page before, unless the connector says it had to clamp
    /// to a trimmed log.
    ///
    /// This is the check the old client could not make: it guessed an offset from
    /// the shortfall instead of knowing, so a skipped stretch of history looked
    /// like a normal page (spec 007 research §3-A).
    private func contiguityViolation(_ page: Page, requested: Int) -> String? {
        guard let first = page.records.first?.event.seq, let last = page.records.last?.event.seq else {
            return page.records.isEmpty ? "empty page" : nil
        }
        if first != page.startSeq { return "first record \(first) != startSeq \(page.startSeq)" }
        if last != page.endSeq { return "last record \(last) != endSeq \(page.endSeq)" }
        if page.endSeq >= requested { return "endSeq \(page.endSeq) is not below the requested \(requested)" }
        if page.endSeq != requested - 1, !page.clamped {
            return "endSeq \(page.endSeq) does not abut the window at \(requested - 1) (and no clamp was reported)"
        }
        return nil
    }

    private func apply(_ page: Page, requested: Int, attempts: Int) -> Outcome {
        let previous = oldest ?? Int.max
        let fresh = page.records.filter { $0.event.seq < previous }
        // The window moves even when every record was already known: otherwise a
        // page made only of duplicates would freeze the reader forever (FR-037).
        let nextOldest = min(previous, page.records.isEmpty ? page.startSeq : page.records[0].event.seq)
        oldest = nextOldest
        newest = max(newest ?? 0, page.endSeq)
        last = page
        state = page.hasMore ? .more : .end
        onDiagnostic?(.page(requested: requested, startSeq: page.startSeq, endSeq: page.endSeq,
                            returned: page.records.count, prepended: fresh.count,
                            attempts: attempts, hasMore: page.hasMore))
        return .prepended(count: fresh.count, oldestSeq: oldest)
    }
}

enum PagerError: Error, CustomStringConvertible {
    case nonContiguous(String)

    var description: String {
        switch self {
        case .nonContiguous(let reason): return "page was not contiguous: \(reason)"
        }
    }
}
