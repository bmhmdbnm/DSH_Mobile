/**
 * `_link/sessionWindow` 的「往下扫」与「把扫描结果裁成一页」两块（spec 007 T065
 * 的同一条理由：让 `history.js` 留得下校验、在飞锁与检索）。
 *
 * 唯一的 IO 是调用方给的 `readChunk`，所以这里没有服务状态、可以直接单测。
 */

import { MAX_CHUNKS_PER_CALL, bytesOfRecords, roleOf, toRecord, trimToBytes } from './records.js'

/// One backward scan from `before - 1` (spec 009 T039).
///
/// Returns the matching events **and** `scannedFloor`: the oldest seq this call
/// actually examined (inclusive). It is about *where the scan got to*, not about
/// which events matched — a page whose whole stretch is filtered out still moves
/// it, which is what lets the phone's role-filtered backfill advance. (The old
/// cursor rule — the oldest returned record — stands still on an empty page.)
///
/// `exhausted` means the scan ran into the start of the log (or an empty chunk):
/// a filtered page needs it to answer "is there more?".
export async function scanOlder({ readChunk, sessionId, before, through, limit, maxBytes, roles }) {
  let cursor = Math.min(before - 1, through ?? Number.MAX_SAFE_INTEGER)
  const events = []
  let truncatedBy = null
  let clamped = false
  let exhausted = false
  let scannedFloor = null
  for (let chunk = 0; chunk < MAX_CHUNKS_PER_CALL && cursor >= 0; chunk += 1) {
    const { window: result, clamped: thisClamped } = await readChunk(sessionId, cursor)
    clamped = clamped || thisClamped
    const batch = Array.isArray(result.events) ? result.events : []
    if (batch.length === 0) { exhausted = true; scannedFloor = 0; break }
    const lowest = result.startSeq ?? batch[0].seq
    scannedFloor = scannedFloor === null ? lowest : Math.min(scannedFloor, lowest)
    for (let index = batch.length - 1; index >= 0; index -= 1) {
      const event = batch[index]
      if (roles !== undefined && !roles.has(roleOf(event))) continue
      events.unshift(event)
    }
    if (events.length >= limit || bytesOfRecords(events.map(toRecord)) >= maxBytes) {
      truncatedBy = events.length >= limit ? 'count' : 'bytes'
      break
    }
    const next = lowest - 1
    if (next >= cursor) { exhausted = true; break }
    cursor = next
    if (cursor < 0) { exhausted = true; break }
  }
  return { events, truncatedBy, clamped, exhausted, scannedFloor }
}

/// Shape one scan into the page the phone gets.
///
/// Trimming only ever drops the **oldest** end: the newest edge is the seq the
/// phone's window abuts, so it must stay exact (one chunk is 51 events, so the
/// page would otherwise overshoot `limit` by up to a chunk).
///
/// `scanBoundary` is what the caller passes as the next `before`. Normally that
/// is `scannedFloor` — the stretch below it was never looked at. When trimming
/// dropped records, it falls back to the oldest **returned** record instead:
/// dropped records were not handed over, so the next page has to scan them
/// again (re-scanning is free, losing one question is not). Without `roles` the
/// field mirrors `startSeq`: old clients read the old fields and see no change.
export function pageFrom(scan, { limit, maxBytes, roles }) {
  const records = scan.events.map(toRecord)
  let truncatedBy = scan.truncatedBy
  let droppedOldest = false
  if (records.length > limit) {
    records.splice(0, records.length - limit)
    truncatedBy = 'count'
    droppedOldest = true
  }
  if (trimToBytes(records, maxBytes)) { truncatedBy = 'bytes'; droppedOldest = true }
  if (records.length === 0) {
    return {
      records: [], startSeq: null, endSeq: null,
      hasMore: roles !== undefined && !scan.exhausted,
      truncatedBy: null, clamped: scan.clamped,
      scanBoundary: roles === undefined ? null : scan.scannedFloor,
    }
  }
  const startSeq = records[0].event.seq
  const endSeq = records[records.length - 1].event.seq
  // Filtered pages: "more" means older seqs remain unscanned **and** the page
  // did not already reach the log's first event.
  const hasMore = roles === undefined ? startSeq > 0 : (startSeq > 0 && !scan.exhausted)
  return {
    records, startSeq, endSeq, hasMore, truncatedBy, clamped: scan.clamped,
    scanBoundary: roles === undefined ? startSeq : (droppedOldest ? startSeq : scan.scannedFloor),
  }
}
