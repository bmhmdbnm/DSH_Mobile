/**
 * HTTP routes under `/mobile-link`, registered on DSH's own web server.
 *
 *   GET  /mobile-link/status     connection + device inventory + setup state
 *   POST /mobile-link/pair-code  mint a pairing code (and its QR payload + SVG)
 *
 * All sit behind DSH's own request fence, like every other plugin route:
 * `ctx.get('connection')?.requestRejection?.(req)` performs the Host/Origin check
 * and browser authentication. `/status` stays readable when the fence service is
 * missing (it is diagnostic); the other two mint a credential, so they fail
 * closed.
 */

import { qrSvg } from './qr.js'

const MAX_BODY_BYTES = 64 * 1024

export function sendJson(res, status, payload) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(payload))
}

export async function readJsonBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.byteLength
    if (size > MAX_BODY_BYTES) {
      req.resume()
      return undefined
    }
    chunks.push(chunk)
  }
  if (size === 0) return {}
  try {
    return JSON.parse(Buffer.concat(chunks, size).toString('utf8'))
  } catch {
    return undefined
  }
}

/**
 * @returns {boolean} true when the request was rejected and the response ended.
 */
export function makeGuard(ctx, logger) {
  const connectionOf = () => (typeof ctx.get === 'function' ? ctx.get('connection') : undefined)
  return function guard(req, res, { requireFence = false } = {}) {
    const connection = connectionOf()
    const fence = connection?.requestRejection
    // DSH's contract is "a status when refused, **undefined** when the request
    // may proceed" — so undefined is a pass, not an absence. Reading it as an
    // absence is what made every privileged route below answer 403 to everyone
    // with a perfectly authenticated request: the pairing page and
    // `POST /pair-code` never got past the guard. The service's own presence is
    // the only thing that can tell "no fence to consult" apart from "fence says
    // yes", so that is what is checked here.
    if (typeof fence !== 'function') {
      if (requireFence) {
        sendJson(res, 403, { ok: false, message: 'the DSH connection service is unavailable; refusing a privileged request' })
        return true
      }
      return false
    }
    let rejection
    try {
      rejection = fence.call(connection, req)
    } catch (error) {
      logger.warn?.(`mobile-link: request fence failed: ${error}`)
      sendJson(res, 403, { ok: false, message: 'request rejected by the DSH fence' })
      return true
    }
    if (rejection !== undefined && rejection !== null) {
      res.statusCode = Number(rejection) || 403
      res.end()
      return true
    }
    return false
  }
}

function ttlFrom(value, fallbackMs) {
  return Number.isFinite(Number(value)) && Number(value) > 0
    ? Math.min(Number(value), 60 * 60 * 1000)
    : fallbackMs
}

/**
 * Register the routes.
 * @returns {Array<() => void>} disposers (already wrapped by the caller in ctx.effect).
 */
export function registerMobileLinkRoutes(ctx, { agent, logger, config = {}, history }) {
  const guard = makeGuard(ctx, logger)
  const STATUS_ROUTE = '/mobile-link/status'
  const PAIR_ROUTE = '/mobile-link/pair-code'
  /// SPIKE（spec 007 / T008）：只读测量宿主窗口与检索 API 的语义。
  /// 默认关闭，只有 `DSH_MOBILE_LINK_HISTORY_PROBE=1` 时注册——它是一次性测量工具，
  /// 不是产品面（结论已写回 specs/007-transcript-history/plan.md 的 Phase 0）。
  const PROBE_ROUTE = '/mobile-link/history-probe'
  const disposers = []

  if (history !== undefined && process.env.DSH_MOBILE_LINK_HISTORY_PROBE === '1') {
    disposers.push(ctx.webServer.register({
      kind: 'exact',
      path: PROBE_ROUTE,
      handler: async (req, res) => {
        if (guard(req, res)) return
        if (req.method !== 'GET') {
          res.statusCode = 405
          res.setHeader('allow', 'GET')
          res.end()
          return
        }
        const url = new URL(req.url ?? '/', 'http://127.0.0.1')
        try {
          const result = await history.probe({
            sessionId: url.searchParams.get('sessionId') ?? '',
            seq: url.searchParams.get('seq') ?? undefined,
            n: url.searchParams.get('n') ?? undefined,
            text: url.searchParams.get('text') ?? undefined,
          })
          sendJson(res, 200, result)
        } catch (error) {
          sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
        }
      },
    }))
  }

  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: STATUS_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res)) return
      if (req.method !== 'GET') {
        res.statusCode = 405
        res.setHeader('allow', 'GET')
        res.end()
        return
      }
      try {
        sendJson(res, 200, agent.status())
      } catch (error) {
        sendJson(res, 500, { ok: false, message: String(error?.message ?? error) })
      }
    },
  }))

  disposers.push(ctx.webServer.register({
    kind: 'exact',
    path: PAIR_ROUTE,
    handler: async (req, res) => {
      if (guard(req, res, { requireFence: true })) return
      if (req.method !== 'POST') {
        res.statusCode = 405
        res.setHeader('allow', 'POST')
        res.end()
        return
      }
      const body = await readJsonBody(req)
      if (body === undefined) {
        sendJson(res, 400, { ok: false, message: 'invalid JSON body' })
        return
      }
      const ttlMs = ttlFrom(body.ttlMs, Number(config.pairTtlMs) || 10 * 60 * 1000)
      try {
        const minted = await agent.mintPairCode({ ttlMs })
        logger.info?.(`mobile-link: minted a pairing code for ${minted.agentId}`)
        // The picture travels with the code. It used to be a route of its own
        // (`GET /mobile-link/qr`) that a person opened in a browser; the pairing
        // entry is now the connector's own panel in the DSH client, so the one
        // caller left is that panel, and it wants the code and the symbol in the
        // same answer. No caption: the panel runs its own countdown, and a
        // server-rendered "还剩 N 分钟" freezes the moment the window is up.
        sendJson(res, 200, { ok: true, ...minted, svg: qrSvg(minted.qrPayload) })
      } catch (error) {
        sendJson(res, 502, { ok: false, code: 'relay/unavailable', message: String(error?.message ?? error) })
      }
    },
  }))

  return disposers
}
