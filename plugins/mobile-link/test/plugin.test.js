/**
 * Wiring tests for the cordis plugin half: route registration, the request
 * fence, and the promise that the link never depends on a DSH service.
 *
 * A fake context stands in for DSH, so no server is started.
 */

import assert from 'node:assert/strict'
import test from 'node:test'

// Point the harness home at a throwaway directory before the plugin is
// imported. Without this the plugin persists the fixture identity below over
// the real `~/.dsh/mobile-link/agent.json` — which silently replaced a working
// connector's credentials with `agt_test`/`as_test` and broke its reconnection.
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-plugin-test-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

import * as plugin from '../lib/index.js'

const BASE_CONFIG = {
  enabled: false,
  relayUrl: 'ws://127.0.0.1:9',
  agentId: 'agt_test',
  agentSecret: 'as_test',
}

function fakeResponse() {
  return {
    statusCode: 200,
    headers: {},
    chunks: [],
    ended: false,
    setHeader(name, value) {
      this.headers[name.toLowerCase()] = value
    },
    end(chunk) {
      this.ended = true
      if (chunk !== undefined) this.chunks.push(String(chunk))
    },
    get body() {
      return this.chunks.join('')
    },
  }
}

function fakeRequest(method = 'GET', body, url = '/') {
  return {
    method,
    url,
    headers: {},
    async *[Symbol.asyncIterator]() {
      if (body !== undefined) yield Buffer.from(JSON.stringify(body))
    },
  }
}

/**
 * @param {'allow'|'missing'|number} fence  how DSH's connection service behaves
 */
function fakeContext({ fence = 'allow', injectable = true } = {}) {
  const routes = new Map()
  const effects = []
  const injected = []
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const webServer = {
    port: 52430,
    register(route) {
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
  }
  const connection = fence === 'missing'
    ? undefined
    : {
      // DSH 的真实契约：拒绝时给状态码，**放行时给 undefined**
      // （`Connection.requestRejection` 的实现就是 `isAuthenticated ? undefined : 401`）。
      // 夹具必须照抄这一点——用 null 表示放行曾把一个真 bug 藏了起来：
      // 插件把 undefined 当成"没有栅栏服务"，于是所有需要栅栏的路由对
      // 已认证的浏览器请求一律 403，配对页和 `POST /pair-code` 谁都用不了。
      requestRejection: () => (fence === 'allow' ? undefined : fence),
      authenticatedUrl: (base) => `${base}/?token=test-token`,
    }
  const get = (service) => (service === 'connection'
    ? connection
    : service === 'webServer' ? webServer : undefined)
  const scope = { webServer, connection, get, effect: (fn, label) => effects.push([label, fn()]) }
  const ctx = {
    logger,
    get,
    effect: (fn, label) => effects.push([label, fn()]),
    inject(services, callback) {
      injected.push(services)
      if (!injectable) throw new Error('service injection is unavailable')
      return callback(scope)
    },
  }
  return { ctx, routes, effects, injected, webServer, logger }
}

test('the plugin advertises no required services', () => {
  assert.equal(plugin.name, 'mobile-link')
  assert.equal(plugin.inject, undefined, 'a DSH service must never be able to block the link')
})

test('apply registers every route through ctx.inject and starts the agent', () => {
  const { ctx, routes, effects, injected } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  assert.deepEqual([...routes.keys()].sort(), ['/mobile-link/pair-code', '/mobile-link/qr', '/mobile-link/status'])
  assert.deepEqual(injected, [['webServer'], ['webServer', 'connection']])
  assert.ok(effects.some(([label]) => label.includes('DLP agent')))
})

test('apply survives a missing webServer service', () => {
  const { ctx, routes } = fakeContext({ injectable: false })
  assert.doesNotThrow(() => plugin.apply(ctx, BASE_CONFIG))
  assert.equal(routes.size, 0)
})

test('a rejected request is passed through with the fence status', async () => {
  const { ctx, routes } = fakeContext({ fence: 403 })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), res)
  assert.equal(res.statusCode, 403)
  assert.equal(res.body, '')

  const refused = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), refused)
  assert.equal(refused.statusCode, 403)
})

test('GET /mobile-link/status answers a JSON snapshot', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), res)
  assert.equal(res.statusCode, 200)
  assert.equal(res.headers['content-type'], 'application/json; charset=utf-8')
  const status = JSON.parse(res.body)
  assert.equal(status.ok, true)
  assert.equal(status.enabled, false)
  assert.equal(status.state, 'disabled')
  assert.equal(status.agentId, 'agt_test')
  assert.deepEqual(status.devices, [])
  assert.equal(status.protocolVersion, 1)
})

test('GET /mobile-link/status stays readable when the fence service is missing', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), res)
  assert.equal(res.statusCode, 200)
  assert.equal(JSON.parse(res.body).ok, true)
})

test('POST /mobile-link/pair-code refuses to mint without the fence service', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), res)
  assert.equal(res.statusCode, 403)
  assert.match(res.body, /connection service is unavailable/)
})

test('POST /mobile-link/pair-code reports an unreachable relay without throwing', async () => {
  // The fence is satisfied; only the relay is unreachable (discard port 9).
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', { ttlMs: 60000 }), res)
  assert.equal(res.statusCode, 502)
  const body = JSON.parse(res.body)
  assert.equal(body.ok, false)
  assert.equal(body.code, 'relay/unavailable')
  assert.match(body.message, /fetch failed|ECONNREFUSED|connect/i)
})

test('wrong HTTP methods get a 405 with Allow', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const status = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('POST', {}), status)
  assert.equal(status.statusCode, 405)
  assert.equal(status.headers.allow, 'GET')

  const pair = fakeResponse()
  await routes.get('/mobile-link/pair-code').handler(fakeRequest('GET'), pair)
  assert.equal(pair.statusCode, 405)
  assert.equal(pair.headers.allow, 'POST')
})

// ── GET /mobile-link/qr ────────────────────────────────────────────────────
//
// The pairing screen is one URL: open it, see a scannable code, with no desktop
// client involvement. `?format=json` is the same content for the tests.
//
// The relay is unreachable here, so `mintPairCode` is stubbed on the prototype:
// the routes call exactly that one method, and standing up a fake relay would
// test the relay instead of the route.

/** Runs `fn` with every agent's `mintPairCode` replaced. */
async function withMint(stub, fn) {
  const original = plugin.MobileLinkAgent.prototype.mintPairCode
  plugin.MobileLinkAgent.prototype.mintPairCode = stub
  try {
    return await fn()
  } finally {
    plugin.MobileLinkAgent.prototype.mintPairCode = original
  }
}

const MINTED = {
  code: 'JKMN-PQRS-TUVW-XYZ2',
  expiresAt: Date.now() + 600_000,
  ttlMs: 600_000,
  relayUrl: 'wss://relay.test/dsh-link',
  agentId: 'agt_x',
  qrPayload: 'dsh://pair?relay=wss%3A%2F%2Frelay.test%2Fdsh-link&code=JKMN-PQRS-TUVW-XYZ2',
}

test('GET /mobile-link/qr renders an SVG when the relay mints a code', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await withMint(async () => MINTED, () =>
    routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res))

  assert.equal(res.statusCode, 200)
  assert.equal(res.headers['content-type'], 'image/svg+xml; charset=utf-8')
  assert.equal(res.headers['cache-control'], 'no-store')
  assert.match(res.body, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/)
  assert.match(res.body, /<path d="M/)
})

test('GET /mobile-link/qr?format=json returns the payload and the SVG', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await withMint(async () => MINTED, () =>
    routes.get('/mobile-link/qr').handler(
      fakeRequest('GET', undefined, '/mobile-link/qr?format=json'), res))

  assert.equal(res.statusCode, 200)
  const body = JSON.parse(res.body)
  assert.equal(body.ok, true)
  assert.equal(body.code, MINTED.code)
  assert.equal(body.qrPayload, MINTED.qrPayload)
  assert.match(body.svg, /^<svg /)
})

test('GET /mobile-link/qr fails closed when the relay is unreachable', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await withMint(async () => { throw new Error('fetch failed') }, () =>
    routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res))

  assert.equal(res.statusCode, 502)
  assert.equal(JSON.parse(res.body).code, 'relay/unavailable')
})

test('GET /mobile-link/qr refuses to mint without the DSH fence', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res)
  assert.equal(res.statusCode, 403)
})

test('GET /mobile-link/qr rejects other methods', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const res = fakeResponse()
  await routes.get('/mobile-link/qr').handler(fakeRequest('POST', {}), res)
  assert.equal(res.statusCode, 405)
  assert.equal(res.headers.allow, 'GET')
})

// 屏幕上那张码只在该换的时候换：刷新页面不该换掉它，被用掉或快过期了才换。
// 这条是"扫了没反应"的一半原因——页面上那张和手机扫到的那张不是同一个状态。

/** Runs `fn` with the prototype's `devices` map reporting a fixed size. */
async function withDeviceCount(read, fn) {
  const proto = plugin.MobileLinkAgent.prototype
  const original = Object.getOwnPropertyDescriptor(proto, 'devices')
  Object.defineProperty(proto, 'devices', { configurable: true, get: () => ({ size: read() }) })
  try {
    return await fn()
  } finally {
    Object.defineProperty(proto, 'devices', original)
  }
}

test('GET /mobile-link/qr keeps one code until it is spent, then mints the next', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  let mints = 0
  let devices = 0
  // 第二张码只剩 30 秒：不足以再扫一次，页面应该自己换掉它。
  const stub = async () => {
    mints += 1
    return {
      ...MINTED,
      expiresAt: Date.now() + (mints === 2 ? 30_000 : 600_000),
      qrPayload: `${MINTED.qrPayload}-${mints}`,
    }
  }
  const render = async () => {
    const res = fakeResponse()
    await routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), res)
    return res.body
  }

  await withMint(stub, () => withDeviceCount(() => devices, async () => {
    const first = await render()
    assert.equal(mints, 1)
    assert.match(first, /有效期至 \d\d:\d\d/, '页面上要写清楚这张码还能用多久')
    assert.equal(await render(), first, '同一张码在刷新时被换掉，人就会去扫屏幕上那张旧的')
    assert.equal(mints, 1)

    devices = 1 // 一台手机用它配上来了
    const second = await render()
    assert.equal(mints, 2, '码被用掉之后必须换一张')
    assert.notEqual(second, first)

    await render()
    assert.equal(mints, 3, '剩下的时间不够再扫一次时也要换一张')
  }))
})

test('GET /mobile-link/qr?format=json says whether the code was re-used', async () => {
  const { ctx, routes } = fakeContext()
  plugin.apply(ctx, BASE_CONFIG)
  const render = async () => {
    const res = fakeResponse()
    await routes.get('/mobile-link/qr').handler(
      fakeRequest('GET', undefined, '/mobile-link/qr?format=json'), res)
    return JSON.parse(res.body)
  }
  await withMint(async () => ({ ...MINTED }), async () => {
    assert.equal((await render()).reused, false)
    assert.equal((await render()).reused, true)
  })
})

test('detectHostForm reads evidence from the process, never from inherited env', () => {
  // 官方桌面版：入口脚本是私有的 dsh-desktop-host，或可执行文件在应用包里。
  assert.equal(plugin.detectHostForm({ argv: ['node', '/x/@deepseek-ai/dsh-desktop-host/lib/index.js'], execPath: '/usr/bin/node' }), 'desktop')
  assert.equal(plugin.detectHostForm({ argv: ['node', '/x/bin/dsh', 'web'], execPath: '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' }), 'desktop')
  // 命令行 web 版：普通 node + dsh 入口。
  assert.equal(plugin.detectHostForm({ argv: ['node', '/x/bin/dsh', 'web'], execPath: '/opt/homebrew/bin/node' }), 'web')
})

test('a web host started from inside the desktop app is NOT misdetected as desktop', () => {
  // 回归：从桌面版宿主里敲 `dsh web` 会继承 ELECTRON_RUN_AS_NODE 之类的环境变量；
  // 早期实现据此判断，结果把 web 宿主报成 desktop（慢闸实测抓到）。
  const inherited = { ELECTRON_RUN_AS_NODE: '1', DSH_HOME: '/tmp/x' }
  const form = plugin.detectHostForm({ ...inherited, argv: ['node', '/opt/homebrew/bin/dsh', 'web'], execPath: '/opt/homebrew/Cellar/node/25.5.0/bin/node' })
  assert.equal(form, 'web', '不能因为继承来的环境变量就判定成桌面版')
})

test('setHostService wires (and clears) the in-process resolver', () => {
  const agent = new plugin.MobileLinkAgent({ enabled: false, relayUrl: 'ws://127.0.0.1:9', logger: console })
  const resolver = () => 'http://127.0.0.1:19387/?token=t'
  agent.setHostService(resolver)
  assert.equal(agent.dsh.hostService, resolver)
  assert.equal(agent.dsh.hostService(), 'http://127.0.0.1:19387/?token=t')
  agent.setHostService(undefined)
  assert.equal(agent.dsh.hostService, undefined)
})

test('the status snapshot carries the host form the plugin set', () => {
  const agent = new plugin.MobileLinkAgent({ enabled: false, relayUrl: 'ws://127.0.0.1:9', logger: console })
  agent.setHostForm('desktop')
  assert.equal(agent.status().host, 'desktop')
  agent.setHostForm('nonsense')
  assert.equal(agent.status().host, 'unknown', '认不出的形态必须落到 unknown，而不是照抄')
})

test('with no connection service the routes stay registered and the privileged ones fail closed', async () => {
  const { ctx, routes } = fakeContext({ fence: 'missing' })
  assert.doesNotThrow(() => plugin.apply(ctx, BASE_CONFIG))
  assert.equal(routes.size, 3, 'connection 缺失不该让路由消失')

  const status = fakeResponse()
  await routes.get('/mobile-link/status').handler(fakeRequest('GET'), status)
  assert.equal(status.statusCode, 200, '/status 是诊断用的，栅栏缺失时仍要能读')

  const qr = fakeResponse()
  await routes.get('/mobile-link/qr').handler(fakeRequest('GET'), qr)
  assert.equal(qr.statusCode, 403, '铸造凭据的路由必须失败关闭')
  assert.match(qr.body, /connection service is unavailable/)
})

test('a fence that says yes (undefined) is a pass, not a missing service', async () => {
  // 回归：DSH 放行时返回 undefined。以前这条被当成"栅栏服务不存在"，
  // 结果是浏览器带着正确凭据打开 `/mobile-link/qr` 永远 403。
  const { ctx, routes } = fakeContext({ fence: 'allow' })
  plugin.apply(ctx, BASE_CONFIG)
  await withMint(async () => ({ ...MINTED }), async () => {
    const qr = fakeResponse()
    await routes.get('/mobile-link/qr').handler(fakeRequest('GET', undefined, '/mobile-link/qr'), qr)
    assert.equal(qr.statusCode, 200, '栅栏放行就必须放行')
    assert.match(qr.body, /^<svg /)

    const pair = fakeResponse()
    await routes.get('/mobile-link/pair-code').handler(fakeRequest('POST', {}), pair)
    assert.equal(pair.statusCode, 200, 'pair-code 同样必须能过')
  })
})
