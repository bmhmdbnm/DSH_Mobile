/**
 * `_link/sessionWindow` / `_link/sessionFind` 共用的事件→记录件。
 *
 * 抽出来的理由与 `shared.js` 同一条（spec 007 T065）：窗口扫描、检索、探针三块
 * 都要按角色归类事件、都要按字节预算裁剪，放在 `history.js` 里会把那个文件撑到
 * 读不动，也确实漏过一次导入（`probe.js` 里 `bytesOf`/`summarizeEvents` 一直是
 * 未定义的名字）。
 *
 * 这里只有纯函数：没有 IO、没有服务状态。
 */

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

export function bytesOf(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), 'utf8')
  } catch {
    return -1
  }
}

export function summarizeEvents(events) {
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

export function toRecord(event) {
  return { type: 'event', event }
}

export function bytesOfRecords(records) {
  return bytesOf(records)
}

/// Drop the **oldest** end until the page fits. The newest edge must stay exact
/// (it is the seq the phone's window abuts), so trimming only ever happens here.
export function trimToBytes(records, maxBytes) {
  let truncated = false
  while (records.length > 1 && bytesOfRecords(records) > maxBytes) {
    records.shift()
    truncated = true
  }
  return truncated
}

/// Which of the three transcript roles one event belongs to (the phone's own
/// `TranscriptSearchHit.Role`).
///
/// `user/message` only counts as **me** when the event really came from the
/// user: measured on a real session, ~24% of `user/message` events are
/// plugin/system injections (`data.source.kind` other than `"user"`), and
/// agent-relayed ones carry a `data.source.rpcId` starting with `agent-`.
/// Events with no `data.source` at all predate the marker and stay `me`
/// (old-data compatibility). Non-`me` user messages return `undefined` —
/// they remain visible to full-text search, they just never enter the
/// "my questions" set (spec 009 T031).
export function roleOf(event) {
  const type = event?.type
  if (type === 'user/message') {
    const source = event?.data?.source
    if (source !== undefined && source !== null && typeof source === 'object') {
      if (source.kind !== undefined && source.kind !== 'user') return undefined
      if (typeof source.rpcId === 'string' && source.rpcId.startsWith('agent-')) return undefined
    }
    return 'me'
  }
  if (type === 'assistant/message') return 'agent'
  if (type === 'tool/call' || type === 'tool/result') return 'tool'
  return undefined
}

/// What the search hit is *displayed* as. Injected/relayed user messages are
/// not "me" for the curated set, but they are still user speech in full-text
/// search (spec 009: excluded from "我的提问", not from the corpus), so an
/// unfiltered search shows them under the user bucket.
export function displayRoleOf(event) {
  return roleOf(event) ?? (event?.type === 'user/message' ? 'me' : undefined)
}
