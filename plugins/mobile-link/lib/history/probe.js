import { withTimeout, messageOf } from './shared.js'

/**
 * 只读测量（spec 007 T008/T047）：`GET /mobile-link/history-probe` 用，锁定映射之后删。
 *
 * 它只读、不改任何状态；`getQuery` 是个取值函数而不是服务对象本身，因为宿主注入
 * （`ctx.inject(['sessionQuery'])`）可能在服务建好之后才发生。
 */
export function createProbeRunner({ getQuery, logger }) {
  return async function probe(args = {}) {
  const sessionId = args.sessionId
  if (typeof sessionId !== 'string' || sessionId.length === 0) {
    return { ok: false, error: 'sessionId is required' }
  }
  if (getQuery() === undefined) {
    return { ok: false, error: 'ctx.getQuery() is not mounted in this Host' }
  }
  const limit = Number.isFinite(Number(args.n)) && Number(args.n) > 0 ? Number(args.n) : 60
  const out = { ok: true, sessionId, limit }

  // 1. Whole log: how many events, and is log position == seq?
  const t0 = Date.now()
  try {
    const records = await withTimeout(getQuery().listEvents(sessionId), HOST_CALL_TIMEOUT_MS, 'listEvents')
    const mismatches = []
    records.forEach((record, index) => {
      if (record.seq !== index && mismatches.length < 5) mismatches.push({ index, seq: record.seq })
    })
    out.listEvents = {
      ...summarizeEvents(records),
      ms: Date.now() - t0,
      offsetEqualsSeq: mismatches.length === 0,
      firstMismatches: mismatches,
    }
  } catch (error) {
    out.listEvents = { ms: Date.now() - t0, error: messageOf(error) }
  }

  // 2. Exact window read around a seq (`readEvent`): raw events, contiguous.
  const targetSeq = Number.isFinite(Number(args.seq)) ? Number(args.seq) : out.listEvents?.lastSeq
  if (Number.isInteger(targetSeq) && targetSeq >= 0) {
    const t1 = Date.now()
    try {
      const window = await withTimeout(
        getQuery().readEvent({ sessionId, seq: targetSeq, before: limit, after: 0 }),
        HOST_CALL_TIMEOUT_MS,
        'readEvent',
      )
      out.readEvent = {
        requested: { seq: targetSeq, before: limit, after: 0 },
        ...summarizeEvents(window.events),
        startSeq: window.startSeq ?? null,
        endSeq: window.endSeq ?? null,
        rawEventCount: window.events?.length ?? 0,
        bytes: bytesOf(window.events),
        ms: Date.now() - t1,
      }
    } catch (error) {
      out.readEvent = { requested: { seq: targetSeq, before: limit }, ms: Date.now() - t1, error: messageOf(error) }
    }
  }

  // 3. Seq-range filter (`filterEvents`): message-aligned semantic documents.
  if (Number.isInteger(targetSeq) && targetSeq >= 0) {
    const from = Math.max(0, targetSeq - limit + 1)
    const t2 = Date.now()
    try {
      const docs = await withTimeout(
        getQuery().filterEvents(sessionId, [{ kind: 'seq', from, to: targetSeq }]),
        HOST_CALL_TIMEOUT_MS,
        'filterEvents(seq)',
      )
      out.filterEventsSeq = {
        requested: { from, to: targetSeq },
        ...summarizeEvents(docs),
        bytes: bytesOf(docs),
        sample: docs.slice(0, 2).map((doc) => ({ seq: doc.seq, type: doc.type, textLen: doc.text?.length ?? 0 })),
        ms: Date.now() - t2,
      }
    } catch (error) {
      out.filterEventsSeq = { requested: { from, to: targetSeq }, ms: Date.now() - t2, error: messageOf(error) }
    }
  }

  // 4. Literal text scan (`filterEvents(text)`): the fallback for search when
  //    the full-text index is closed (base bundle ships `openAt: never`).
  if (typeof args.text === 'string' && args.text.length > 0) {
    const t3 = Date.now()
    try {
      const docs = await withTimeout(
        getQuery().filterEvents(sessionId, [{ kind: 'text', text: args.text }]),
        HOST_CALL_TIMEOUT_MS,
        'filterEvents(text)',
      )
      out.filterEventsText = {
        query: args.text,
        ...summarizeEvents(docs),
        sample: docs.slice(0, 3).map((doc) => ({
          seq: doc.seq,
          type: doc.type,
          textLen: doc.text?.length ?? 0,
          head: (doc.text ?? '').slice(0, 60),
        })),
        ms: Date.now() - t3,
      }
    } catch (error) {
      out.filterEventsText = { query: args.text, ms: Date.now() - t3, error: messageOf(error) }
    }
  }

  // 5. Indexed search (`searchEvents`): expected to fail while the SQLite
  //    index is closed, which is why step 4 must be able to carry search.
  if (typeof args.text === 'string' && args.text.length > 0) {
    const t4 = Date.now()
    try {
      const page = await withTimeout(
        getQuery().searchEvents({ sessionId, query: args.text, limit: 20 }),
        HOST_CALL_TIMEOUT_MS,
        'searchEvents',
      )
      out.searchEvents = {
        query: args.text,
        count: page.items?.length ?? 0,
        hasMore: page.hasMore ?? null,
        first: page.items?.[0] ? { seq: page.items[0].seq, type: page.items[0].type } : null,
        ms: Date.now() - t4,
      }
    } catch (error) {
      out.searchEvents = { query: args.text, ms: Date.now() - t4, error: messageOf(error) }
    }
  }

  // 7. Chunked literal scan: `filterEvents(text)` returns every match with its
  //    full text, so the connector must bound each call by a seq range and
  //    stop at the requested hit count. This measures that shape.
  if (typeof args.text === 'string' && args.text.length > 0 && Number.isInteger(out.listEvents?.lastSeq ?? null)) {
    const chunk = Number.isFinite(Number(args.chunk)) && Number(args.chunk) > 0 ? Number(args.chunk) : 2000
    const wanted = Number.isFinite(Number(args.hits)) && Number(args.hits) > 0 ? Number(args.hits) : 50
    const lastSeq = out.listEvents.lastSeq
    const t6 = Date.now()
    const hits = []
    let calls = 0
    let to = lastSeq
    try {
      while (to >= 0 && hits.length < wanted && calls < 50) {
        const from = Math.max(0, to - chunk + 1)
        const docs = await withTimeout(
          getQuery().filterEvents(sessionId, [
            { kind: 'seq', from, to },
            { kind: 'text', text: args.text },
          ]),
          HOST_CALL_TIMEOUT_MS,
          `filterEvents(chunk ${from}-${to})`,
        )
        calls++
        for (const doc of docs) {
          if (hits.length >= wanted) break
          hits.push({ seq: doc.seq, type: doc.type, textLen: doc.text?.length ?? 0 })
        }
        to = from - 1
      }
      out.chunkedText = {
        query: args.text,
        chunk,
        calls,
        hits: hits.length,
        firstSeq: hits[0]?.seq ?? null,
        lastSeq: hits[hits.length - 1]?.seq ?? null,
        scannedFrom: to + 1,
        ms: Date.now() - t6,
      }
    } catch (error) {
      out.chunkedText = { query: args.text, calls, hits: hits.length, ms: Date.now() - t6, error: messageOf(error) }
    }
  }

  // 6. Cold read: no Agent activation. `readSession` returns the log snapshot.
  const t5 = Date.now()
  try {
    const snapshot = await withTimeout(getQuery().readSession(sessionId), HOST_CALL_TIMEOUT_MS, 'readSession')
    out.readSession = {
      events: snapshot.events?.length ?? null,
      startSeq: snapshot.startSeq ?? null,
      endSeq: snapshot.endSeq ?? null,
      headerKeys: snapshot.session ? Object.keys(snapshot.session).slice(0, 8) : [],
      ms: Date.now() - t5,
    }
  } catch (error) {
    out.readSession = { ms: Date.now() - t5, error: messageOf(error) }
  }

  return out
  }
}
