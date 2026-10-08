import test from 'node:test'
import assert from 'node:assert/strict'

import {
  WINDOW_METHOD, FIND_METHOD, WINDOW_CHUNK, DEFAULT_MAX_BYTES,
  createHistoryService, isHistoryMethod,
} from '../lib/history.js'

/// A synthetic log: one event per seq, `0 .. count - 1`.
function makeLog(count, { bigAt = new Map() } = {}) {
  return Array.from({ length: count }, (_, seq) => ({
    seq,
    type: seq % 3 === 0 ? 'user/message' : 'assistant/message',
    time: 1_700_000_000_000 + seq,
    data: bigAt.has(seq) ? { text: 'x'.repeat(bigAt.get(seq)) } : { text: `event ${seq}` },
  }))
}

/// The Host's own service, with the two behaviours the spike measured: a hard
/// cap of 50 on `before`, and a thrown error when the seq does not exist.
function fakeQuery(log, { delayMs = 0, onCall } = {}) {
  const calls = []
  return {
    calls,
    async readEvent({ sessionId, seq, before, after }) {
      calls.push({ method: 'readEvent', sessionId, seq, before, after })
      if (onCall) await onCall({ seq })
      if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs))
      if (!Number.isInteger(before) || before < 0 || before > 50) {
        throw new Error('before must be an integer between 0 and 50')
      }
      if (!Number.isInteger(seq) || seq < 0 || seq >= log.length) {
        throw new Error(`session "${sessionId}" has no event at seq ${seq}`)
      }
      const start = Math.max(0, seq - before)
      const events = log.slice(start, seq + 1)
      return { sessionId, events, startSeq: start, endSeq: seq }
    },
    async listEvents(sessionId) {
      calls.push({ method: 'listEvents', sessionId })
      return log.map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time }))
    },
  }
}

const ADDRESS = { kind: 'session', sessionId: 'session-test' }

function bound(service, query) {
  service.bindQuery(query)
  return service
}

test('isHistoryMethod only claims the two reserved methods', () => {
  assert.equal(isHistoryMethod(WINDOW_METHOD), true)
  assert.equal(isHistoryMethod(FIND_METHOD), true)
  assert.equal(isHistoryMethod('session/page'), false)
})

test('without an injected service the answer is link/unsupported', async () => {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100 })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'link/unsupported')
})

test('a window ends exactly at before-1 and is contiguous', async () => {
  const log = makeLog(500)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 60 })
  assert.equal(result.ok, true)
  const { records, startSeq, endSeq, hasMore } = result.value
  assert.equal(endSeq, 299, 'the newest edge is the seq the phone asked to end before')
  assert.equal(records[records.length - 1].event.seq, 299)
  assert.equal(records[0].event.seq, startSeq)
  assert.equal(records.length, 60, 'limit bounds the page')
  assert.equal(hasMore, true)
  const seqs = records.map((record) => record.event.seq)
  assert.deepEqual(seqs, Array.from({ length: 60 }, (_, index) => startSeq + index), 'no holes')
})

test('the log start is reported as "no more" instead of a hole', async () => {
  const log = makeLog(20)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 20, limit: 60 })
  assert.equal(result.value.startSeq, 0)
  assert.equal(result.value.endSeq, 19)
  assert.equal(result.value.hasMore, false)
})

test('the byte budget trims the oldest end and keeps the newest edge exact', async () => {
  // One huge event sits at the oldest end of the page; it must be the one dropped.
  const log = makeLog(120, { bigAt: new Map([[60, DEFAULT_MAX_BYTES]]) })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100, limit: 60 })
  const { records, endSeq, startSeq, truncatedBy } = result.value
  assert.equal(endSeq, 99)
  assert.equal(records[records.length - 1].event.seq, 99)
  assert.ok(startSeq > 41, `the oversized oldest event should be gone (startSeq=${startSeq})`)
  assert.equal(truncatedBy, 'bytes')
})

test('a request past a trimmed log clamps to the newest seq and says so', async () => {
  const log = makeLog(30)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 5000, limit: 10 })
  assert.equal(result.ok, true)
  assert.equal(result.value.endSeq, 29, 'clamped to the newest event the Host still has')
  assert.equal(result.value.clamped, true, 'the phone must be able to tell a trimmed log from a hole')
})

test('a normal page is not marked as clamped', async () => {
  const log = makeLog(200)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 100, limit: 10 })
  assert.equal(result.value.clamped, false)
})

test('a second window on the same session is refused as busy, not queued', async () => {
  const log = makeLog(500)
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const service = bound(
    createHistoryService({ logger: { warn() {}, info() {} } }),
    fakeQuery(log, { onCall: () => gate }),
  )
  const first = service.handle(WINDOW_METHOD, { address: ADDRESS, before: 400, limit: 10 })
  const second = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 300, limit: 10 })
  assert.equal(second.ok, false)
  assert.equal(second.error.code, 'link/busy')
  release()
  assert.equal((await first).ok, true)
})

test('a host call that never answers becomes link/timeout', async () => {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery({
    readEvent: () => new Promise(() => {}),
    listEvents: async () => [],
  })
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 10, limit: 5 })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'link/timeout')
})

test('bad arguments are rejected before any host call', async () => {
  const log = makeLog(50)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  assert.equal((await service.handle(WINDOW_METHOD, { address: { kind: 'session' }, before: 10 })).error.code, 'gateway/bad-request')
  assert.equal((await service.handle(WINDOW_METHOD, { address: ADDRESS, before: -1 })).error.code, 'gateway/bad-request')
  assert.equal(query.calls.length, 0, 'nothing reached the Host')
})

test('an unknown session is reported as session/unknown', async () => {
  const service = createHistoryService({ logger: { warn() {}, info() {} } })
  service.bindQuery({
    readEvent: async () => { throw new Error('session "x" not found') },
    listEvents: async () => [],
  })
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 10 })
  assert.equal(result.error.code, 'session/unknown')
})

test('a subagent address reads the child session', async () => {
  const log = makeLog(80)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  await service.handle(WINDOW_METHOD, {
    address: { kind: 'subagent', parentSessionId: 'p', childSessionId: 'child', mode: 'unknown' },
    before: 60,
    limit: 5,
  })
  assert.equal(query.calls[0].sessionId, 'child')
})

test('chunking never asks the Host for more than its own cap', async () => {
  const log = makeLog(600)
  const query = fakeQuery(log)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(WINDOW_METHOD, { address: ADDRESS, before: 400, limit: 120 })
  assert.equal(result.ok, true)
  assert.equal(result.value.records.length, 120)
  for (const call of query.calls.filter((entry) => entry.method === 'readEvent')) {
    assert.ok(call.before <= WINDOW_CHUNK, `asked for ${call.before}, cap is ${WINDOW_CHUNK}`)
  }
})

test('in-session search is answered once the service is bound', async () => {
  const log = makeLog(50)
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeQuery(log))
  // `fakeQuery` 没有 `filterEvents`：能力在但这条调用会炸，因此必须回可重试的错误，
  // 而不是"未实现"那一类。
  const result = await service.handle(FIND_METHOD, { address: ADDRESS, query: 'xx' })
  assert.notEqual(result.error?.code, 'link/not-implemented')
})

// ---------------------------------------------------------------------------
// _link/sessionFind（spec 007 T034/T035）
// ---------------------------------------------------------------------------

/// The Host service with an event corpus and `filterEvents` implementing the
/// "seq range AND literal text" semantics the connector relies on.
function fakeSearchQuery(log, { searchEvents } = {}) {
  return {
    async readEvent() { throw new Error('unused') },
    async listEvents(sessionId) {
      return log.map((event) => ({ sessionId, seq: event.seq, type: event.type, time: event.time }))
    },
    async filterEvents(_sessionId, filters) {
      const range = filters.find((f) => f.kind === 'seq')
      const text = filters.find((f) => f.kind === 'text')?.text ?? ''
      return log
        .filter((event) => event.seq >= range.from && event.seq <= range.to)
        .filter((event) => String(event.data?.text ?? '').toLowerCase().includes(text.toLowerCase()))
        .map((event) => ({ seq: event.seq, type: event.type, time: event.time, text: event.data?.text ?? '' }))
    },
    ...(searchEvents === undefined ? {} : { searchEvents }),
  }
}

/// One searchable event per seq: every 4th is a user message mentioning `needle`.
function searchLog(count) {
  return Array.from({ length: count }, (_, seq) => ({
    seq,
    type: seq % 4 === 0 ? 'user/message' : (seq % 4 === 1 ? 'assistant/message' : 'tool/result'),
    time: 1_700_000_000_000 + seq,
    data: { text: seq % 4 === 0 ? `question ${seq} about needle` : `answer ${seq} about needle` },
  }))
}

const FIND_ARGS = { address: ADDRESS, query: 'needle' }

test('sessionFind returns hits with seq, role and highlight offsets', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 3, chunk: 40 })
  assert.equal(result.ok, true)
  assert.equal(result.value.hits.length, 3)
  assert.equal(result.value.source, 'scan')
  for (const hit of result.value.hits) {
    assert.ok(Number.isSafeInteger(hit.seq))
    assert.ok(['me', 'agent', 'tool'].includes(hit.role))
    assert.equal(hit.snippet.slice(hit.highlightStart, hit.highlightStart + hit.highlightLength), 'needle')
  }
  const seqs = result.value.hits.map((hit) => hit.seq)
  assert.deepEqual(seqs, [...seqs].sort((a, b) => b - a), '新的在前')
})

test('sessionFind pages older hits through the cursor', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const first = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 4, chunk: 10 })
  assert.equal(first.ok, true)
  assert.equal(first.value.hits.length, 4)
  assert.equal(first.value.hasMore, true)
  assert.ok(first.value.cursor !== null)
  const second = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 4, chunk: 10, cursor: first.value.cursor })
  assert.equal(second.ok, true)
  const seqs = [...first.value.hits, ...second.value.hits].map((hit) => hit.seq)
  assert.equal(new Set(seqs).size, seqs.length, '两页不重复')
  assert.ok(Math.max(...second.value.hits.map((h) => h.seq)) < Math.min(...first.value.hits.map((h) => h.seq)),
    '第二页更旧')
})

test('sessionFind honours the role filter (only my own questions)', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(40)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, roles: ['me'], limit: 20, chunk: 40 })
  assert.equal(result.ok, true)
  assert.ok(result.value.hits.length > 0)
  assert.ok(result.value.hits.every((hit) => hit.role === 'me'))
})

test('sessionFind refuses a query that is too short', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(20)))
  const result = await service.handle(FIND_METHOD, { address: ADDRESS, query: 'x' })
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'link/query-too-short')
})

test('sessionFind uses the index when the deployment has one', async () => {
  let calls = 0
  const query = fakeSearchQuery(searchLog(40), {
    searchEvents: async () => {
      calls += 1
      return { items: [{ seq: 12, type: 'user/message', snippet: 'a needle here', time: 1 }], hasMore: false }
    },
  })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 5 })
  assert.equal(result.ok, true)
  assert.equal(result.value.source, 'index')
  assert.equal(calls, 1)
  assert.equal(result.value.hits[0].seq, 12)
})

test('sessionFind falls back to scanning when the index is closed', async () => {
  const query = fakeSearchQuery(searchLog(40), {
    searchEvents: async () => { throw new Error('session search is disabled') },
  })
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), query)
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 3, chunk: 40 })
  assert.equal(result.ok, true)
  assert.equal(result.value.source, 'scan')
  assert.equal(result.value.hits.length, 3)
})

test('sessionFind caps how much it scans per call', async () => {
  const service = bound(createHistoryService({ logger: { warn() {}, info() {} } }), fakeSearchQuery(searchLog(2000)))
  const result = await service.handle(FIND_METHOD, { ...FIND_ARGS, limit: 1000, chunk: 10 })
  assert.ok(result.value.scannedChunks <= 4, `扫了 ${result.value.scannedChunks} 块，上限是 4`)
  assert.equal(result.value.hasMore, true)
})
