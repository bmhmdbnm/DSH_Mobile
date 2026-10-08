import { withTimeout, messageOf } from './history/shared.js'
import { createProbeRunner } from './history/probe.js'

/**
 * History window reads and in-session search, answered **locally** by the connector.
 *
 * Why local: the Host already owns a correct, seq-exact reader
 * (`ctx.sessionQuery`, see @deepseek-ai/dsh-session-query) but does **not** expose
 * it over the remote API the phone talks to. The only history method on that
 * surface is `session/page`, whose `beforeSeq` lands in log-offset space, so a
 * session containing offset-only events silently skips a stretch of history —
 * measured at 235 seqs on a real session (see DSHKit's TranscriptPageBoundary).
 *
 * So the connector reads the Host's own state through the injected service and
 * answers two extra methods:
 *
 *   _link/sessionWindow  exact window ending before a given seq
 *   _link/sessionFind    literal text search within one session
 *
 * Feature detection is the switch, not version comparison: a connector that
 * lacks the injected service answers `link/unsupported`, and the phone keeps
 * using `session/page`. Nothing about the existing methods changes.
 *
 * SPIKE NOTE (spec 007, task T008): `probe()` below is a temporary read-only
 * measurement used to pick the exact Host API mapping. It is wired to
 * `GET /mobile-link/history-probe` and is removed once the mapping is locked.
 */

export const WINDOW_METHOD = '_link/sessionWindow'
export const FIND_METHOD = '_link/sessionFind'

/// Declared in `_link/hello`; the phone switches channels on these.
export const HISTORY_CAPABILITIES = ['history-window', 'session-search']

/// Host-side call ceiling. The connector's inbox is serial, so one slow query
/// would otherwise hold up every other frame on the tunnel.
export const HOST_CALL_TIMEOUT_MS = 8000

export function isHistoryMethod(method) {
  return method === WINDOW_METHOD || method === FIND_METHOD
}

function bytesOf(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), 'utf8')
  } catch {
    return -1
  }
}

function summarizeEvents(events) {
  if (!Array.isArray(events) || events.length === 0) {
    return { count: 0, firstSeq: null, lastSeq: null, types: [] }
  }
  const types = [...new Set(events.map((event) => event?.type).filter(Boolean))].slice(0, 8)
  return {
    count: events.length,
    firstSeq: events[0]?.seq ?? null,
    lastSeq: events[events.length - 1]?.seq ?? null,
    types,
  }
}

/// Host hard cap: `readEvent` rejects `before > 50` (`before must be an integer
/// between 0 and 50`). One chunk therefore yields at most 51 raw events.
export const WINDOW_CHUNK = 50

/// Defaults for one page. The phone may override both; the byte budget wins when
/// they disagree (measured: 51 raw events can already be 253KB on a long session).
export const DEFAULT_LIMIT = 60
export const DEFAULT_MAX_BYTES = 256 * 1024

/// Ceiling on how much one call reads, so a page request can never pin the
/// connector's serial inbox (measured: ~30ms per chunk on a 2.3k session).
export const MAX_CHUNKS_PER_CALL = 12

/// One search chunk, and how many of them one call may scan. Measured on a
/// 12968-event session: ~320ms per 2000-event chunk, so four chunks keep a call
/// near 1.3s — well inside the 8s host-call budget and short enough not to hold
/// the connector's single inbound chain for long (spec 007 FR-019).
export const SEARCH_CHUNK = 2000
export const MAX_SEARCH_CHUNKS_PER_CALL = 4
export const DEFAULT_SEARCH_LIMIT = 50
export const MIN_QUERY_LENGTH = 2

function idOfAddress(address) {
  if (address === null || typeof address !== 'object') return undefined
  if (address.kind === 'session') return typeof address.sessionId === 'string' ? address.sessionId : undefined
  if (address.kind === 'subagent') {
    return typeof address.childSessionId === 'string' ? address.childSessionId : undefined
  }
  return undefined
}

function toRecord(event) {
  return { type: 'event', event }
}

function bytesOfRecords(records) {
  return bytesOf(records)
}

/// Drop the **oldest** end until the page fits. The newest edge must stay exact
/// (it is the seq the phone's window abuts), so trimming only ever happens here.
function trimToBytes(records, maxBytes) {
  let truncated = false
  while (records.length > 1 && bytesOfRecords(records) > maxBytes) {
    records.shift()
    truncated = true
  }
  return truncated
}

/// Which of the three transcript roles one event belongs to (the phone's own
/// `TranscriptSearchHit.Role`).
function roleOf(type) {
  if (type === 'user/message') return 'me'
  if (type === 'assistant/message') return 'agent'
  if (type === 'tool/call' || type === 'tool/result') return 'tool'
  return undefined
}

/// A hit snippet with the highlight offsets the phone's list already renders.
///
/// Offsets, not ranges: the value crosses the wire and a character offset stays
/// meaningful on the other side.
function makeSnippet(text, query, radius = 36) {
  const haystack = String(text ?? '')
  const at = haystack.toLowerCase().indexOf(query.toLowerCase())
  if (at < 0) {
    const head = haystack.slice(0, radius * 2).replace(/\s+/g, ' ').trim()
    return { snippet: head, highlightStart: 0, highlightLength: 0 }
  }
  const start = Math.max(0, at - radius)
  const end = Math.min(haystack.length, at + query.length + radius)
  const snippet = haystack.slice(start, end).replace(/\s+/g, ' ').trim()
  // Re-find the match inside the flattened snippet so the offsets line up with
  // what is actually displayed.
  const flatAt = snippet.toLowerCase().indexOf(query.toLowerCase())
  return {
    snippet,
    highlightStart: flatAt < 0 ? 0 : flatAt,
    highlightLength: flatAt < 0 ? 0 : query.length,
  }
}

function failure(code, message, details = {}) {
  return { ok: false, error: { code, message, details } }
}

/// Map a thrown Host/gateway error onto the contract's codes.
function hostFailure(error) {
  const message = messageOf(error)
  if (/timed out after/.test(message)) return failure('link/timeout', message)
  if (/not found|no such session/i.test(message)) return failure('session/unknown', message)
  return failure('gateway/failed', message)
}

/**
 * @param {{ logger?: { warn?: Function, info?: Function } }} deps
 */
export function createHistoryService({ logger = console } = {}) {
  let sessionQuery
  const probeRunner = createProbeRunner({ getQuery: () => sessionQuery, logger })
  /// Set to false after the Host has told us its full-text index is closed
  /// (`openAt: "never"`), so later searches go straight to the scan.
  let indexSearchable = true
  const inFlight = new Set()
  const lastSeqCache = new Map()

  /// The log's newest seq, cached briefly: it is only needed to clamp a request
  /// that runs past the end (a session can be trimmed between two pages).
  async function newestSeq(sessionId) {
    const cached = lastSeqCache.get(sessionId)
    if (cached !== undefined && Date.now() - cached.at < 5000) return cached.seq
    const records = await withTimeout(sessionQuery.listEvents(sessionId), HOST_CALL_TIMEOUT_MS, 'listEvents')
    const seq = records.length > 0 ? records[records.length - 1].seq : -1
    lastSeqCache.set(sessionId, { at: Date.now(), seq })
    return seq
  }

  /// One exact backward window ending at `seq` (inclusive).
  ///
  /// `clamped` is reported upward: when the session was trimmed, the page cannot
  /// abut the phone's window, and the phone needs to know that the gap is the
  /// log's doing rather than a hole it should treat as a bug (FR-002/FR-041).
  async function readChunk(sessionId, seq) {
    try {
      const window = await withTimeout(
        sessionQuery.readEvent({ sessionId, seq, before: WINDOW_CHUNK, after: 0 }),
        HOST_CALL_TIMEOUT_MS,
        'readEvent',
      )
      return { window, clamped: false }
    } catch (error) {
      // Past the end of a trimmed log: clamp once and retry, never guess.
      if (!/has no event at seq/.test(messageOf(error))) throw error
      const newest = await newestSeq(sessionId)
      if (newest < 0 || newest >= seq) throw error
      lastSeqCache.delete(sessionId)
      const window = await withTimeout(
        sessionQuery.readEvent({ sessionId, seq: newest, before: WINDOW_CHUNK, after: 0 }),
        HOST_CALL_TIMEOUT_MS,
        'readEvent(clamped)',
      )
      return { window, clamped: true }
    }
  }

  /// One page of in-session literal search (spec 007 FR-010…FR-012).
  ///
  /// Preferred path is the Host's indexed `searchEvents`; this deployment ships it
  /// disabled (`openAt: "never"`), so the working path is a bounded scan: chunks of
  /// `SEARCH_CHUNK` seqs, filtered by seq range **and** the literal text, newest
  /// first. Each call scans at most `MAX_SEARCH_CHUNKS_PER_CALL` chunks and hands
  /// back a cursor, so "keep looking older" is the reader's next request rather
  /// than one call that holds the tunnel.
  async function find(args) {
    const sessionId = idOfAddress(args.address)
    if (sessionId === undefined) return failure('gateway/bad-request', 'address must name a session')
    const query = typeof args.query === 'string' ? args.query.trim() : ''
    if (query.length < MIN_QUERY_LENGTH) {
      return failure('link/query-too-short', `query must be at least ${MIN_QUERY_LENGTH} characters`)
    }
    const limit = Number.isSafeInteger(Number(args.limit)) && Number(args.limit) > 0
      ? Math.min(Number(args.limit), 200) : DEFAULT_SEARCH_LIMIT
    const roles = Array.isArray(args.roles) && args.roles.length > 0 ? new Set(args.roles) : undefined
    // Advanced knob (also used by the measurement route and the tests): a smaller
    // chunk makes the cursor path reachable on short sessions. Clamped, never 0.
    const chunk = Number.isSafeInteger(Number(args.chunk)) && Number(args.chunk) > 0
      ? Math.min(Number(args.chunk), SEARCH_CHUNK) : SEARCH_CHUNK
    const key = `find:${sessionId}`
    if (inFlight.has(key)) return failure('link/busy', 'another search is in flight for this session')
    inFlight.add(key)
    try {
      // Fast path when the deployment has the index open. One attempt, and a
      // refusal is remembered: the scan below is the path that always works.
      if (indexSearchable && args.cursor === undefined && typeof sessionQuery.searchEvents === 'function') {
        try {
          const page = await withTimeout(
            sessionQuery.searchEvents({ sessionId, query, limit }),
            HOST_CALL_TIMEOUT_MS,
            'searchEvents',
          )
          const indexed = (page.items ?? [])
            .map((item) => {
              const role = roleOf(item.type)
              if (role === undefined) return undefined
              if (roles !== undefined && !roles.has(role)) return undefined
              return { seq: item.seq, role, ...makeSnippet(item.snippet ?? item.text ?? '', query) }
            })
            .filter(Boolean)
          return {
            ok: true,
            value: {
              hits: indexed,
              cursor: page.hasMore === true && page.cursor !== undefined ? String(page.cursor) : null,
              hasMore: page.hasMore === true,
              source: 'index',
            },
          }
        } catch (error) {
          indexSearchable = false
          logger.info?.(`mobile-link: full-text index unavailable, scanning instead: ${messageOf(error)}`)
        }
      }
      const from = parseSearchCursor(args.cursor)
      const ceiling = from !== undefined ? from : await newestSeq(sessionId)
      const hits = []
      let to = ceiling
      let scanned = 0
      while (to >= 0 && hits.length < limit && scanned < MAX_SEARCH_CHUNKS_PER_CALL) {
        const chunkFrom = Math.max(0, to - chunk + 1)
        const docs = await withTimeout(
          sessionQuery.filterEvents(sessionId, [
            { kind: 'seq', from: chunkFrom, to },
            { kind: 'text', text: query },
          ]),
          HOST_CALL_TIMEOUT_MS,
          'filterEvents(search)',
        )
        scanned += 1
        // Newest first inside the chunk: the reader asked about something recent
        // far more often than about something old.
        for (let index = docs.length - 1; index >= 0; index -= 1) {
          const doc = docs[index]
          const role = roleOf(doc.type)
          if (role === undefined) continue
          if (roles !== undefined && !roles.has(role)) continue
          hits.push({ seq: doc.seq, role, ...makeSnippet(doc.text, query) })
          if (hits.length >= limit) break
        }
        to = chunkFrom - 1
      }
      const hasMore = to >= 0 && hits.length >= limit ? true : to >= 0
      return {
        ok: true,
        value: {
          hits,
          cursor: hasMore ? String(to) : null,
          hasMore,
          scannedChunks: scanned,
          source: 'scan',
        },
      }
    } catch (error) {
      logger.warn?.(`mobile-link: sessionFind failed: ${messageOf(error)}`)
      return hostFailure(error)
    } finally {
      inFlight.delete(key)
    }
  }

  /// The cursor is the next `to` seq — opaque to the phone, validated here.
  function parseSearchCursor(cursor) {
    if (typeof cursor !== 'string' || cursor.length === 0) return undefined
    const value = Number(cursor)
    return Number.isSafeInteger(value) && value >= 0 ? value : undefined
  }

  async function window(args) {
    const sessionId = idOfAddress(args.address)
    const before = Number(args.before)
    if (sessionId === undefined) return failure('gateway/bad-request', 'address must name a session')
    if (!Number.isSafeInteger(before) || before < 0) return failure('gateway/bad-request', 'before must be a non-negative integer')
    const limit = Number.isSafeInteger(Number(args.limit)) && Number(args.limit) > 0 ? Number(args.limit) : DEFAULT_LIMIT
    const maxBytes = Number.isSafeInteger(Number(args.maxBytes)) && Number(args.maxBytes) > 0
      ? Number(args.maxBytes) : DEFAULT_MAX_BYTES
    const through = Number.isSafeInteger(Number(args.through)) ? Number(args.through) : undefined

    const key = `window:${sessionId}`
    if (inFlight.has(key)) return failure('link/busy', 'another window read is in flight for this session')
    inFlight.add(key)
    try {
      let cursor = Math.min(before - 1, through ?? Number.MAX_SAFE_INTEGER)
      const events = []
      let truncatedBy = null
      let clamped = false
      for (let chunk = 0; chunk < MAX_CHUNKS_PER_CALL && cursor >= 0; chunk += 1) {
        const { window: result, clamped: thisClamped } = await readChunk(sessionId, cursor)
        clamped = clamped || thisClamped
        const batch = Array.isArray(result.events) ? result.events : []
        if (batch.length === 0) break
        for (let index = batch.length - 1; index >= 0; index -= 1) events.unshift(batch[index])
        if (events.length >= limit || bytesOfRecords(events.map(toRecord)) >= maxBytes) {
          truncatedBy = events.length >= limit ? 'count' : 'bytes'
          break
        }
        const next = (result.startSeq ?? batch[0].seq) - 1
        if (next >= cursor) break
        cursor = next
        if (cursor < 0) break
      }
      const records = events.map(toRecord)
      // Trim from the oldest end only: the newest edge is the seq the phone's
      // window abuts, so it must stay exact. A chunk is 51 events, so without
      // this the page would overshoot `limit` by up to one chunk.
      if (records.length > limit) {
        records.splice(0, records.length - limit)
        truncatedBy = 'count'
      }
      if (trimToBytes(records, maxBytes)) truncatedBy = 'bytes'
      if (records.length === 0) {
        return { ok: true, value: { records: [], startSeq: null, endSeq: null, hasMore: false, truncatedBy: null, clamped } }
      }
      const startSeq = records[0].event.seq
      const endSeq = records[records.length - 1].event.seq
      return { ok: true, value: { records, startSeq, endSeq, hasMore: startSeq > 0, truncatedBy, clamped } }
    } catch (error) {
      logger.warn?.(`mobile-link: sessionWindow failed: ${messageOf(error)}`)
      return hostFailure(error)
    } finally {
      inFlight.delete(key)
    }
  }

  return {
    /// Called from an optional injection; absent on Hosts that predate the service.
    bindQuery(service) {
      sessionQuery = service
      logger.info?.('mobile-link: history service bound to ctx.sessionQuery')
    },
    get available() {
      return sessionQuery !== undefined
    },

    /// Frame handler for the two methods.
    async handle(method, args = {}) {
      if (sessionQuery === undefined) {
        return failure('link/unsupported', 'this Host does not expose the session query service')
      }
      if (method === WINDOW_METHOD) return window(args)
      if (method === FIND_METHOD) return find(args)
      return failure('link/unknown-method', String(method))
    },

    /// Exposed for the unit tests and the (gated) measurement route.
    /// 只读测量（spec 007 T008/T047）：实现见 `history/probe.js`。
    async probe(args = {}) {
      return probeRunner(args)
    },
  }
}
