import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { registerScreenshotRoute, SCREENSHOT_ROUTE } from '../lib/screenshot-route.js'

/** 路由注册的桩：记下落表项，返回 disposer。 */
function makeScope({ rejection, missingFence = false } = {}) {
  const routes = []
  const scope = {
    webServer: {
      register: (route) => {
        routes.push(route)
        return () => { routes.splice(routes.indexOf(route), 1) }
      },
    },
  }
  if (!missingFence) scope.connection = { requestRejection: () => rejection }
  return { scope, routes }
}

function makeRes() {
  return {
    statusCode: 0,
    headers: {},
    body: undefined,
    setHeader(key, value) { this.headers[key] = value },
    end(body) { this.ended = true; this.body = body },
  }
}

function makeReq(sessionId) {
  const payload = sessionId === undefined ? '' : JSON.stringify({ sessionId })
  return {
    method: 'POST',
    async *[Symbol.asyncIterator]() {
      if (payload) yield Buffer.from(payload)
    },
  }
}

test('the route registers as an exact path and returns a disposer', () => {
  const { scope, routes } = makeScope({ rejection: undefined })
  const dispose = registerScreenshotRoute(scope, { logger: { warn() {} } })
  assert.equal(routes.length, 1)
  assert.equal(routes[0].path, SCREENSHOT_ROUTE)
  assert.equal(routes[0].kind, 'exact')
  assert.equal(typeof dispose, 'function')
  dispose()
  assert.equal(routes.length, 0, 'disposer 必须能把路由撤掉（插件禁用时走这条）')
})

test('the fence is read from the injected scope property, not only from ctx.get', async () => {
  const { scope, routes } = makeScope({ rejection: undefined })
  scope.get = () => undefined
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => ({ kind: 'cancelled' }),
  })
  const res = makeRes()
  await routes[0].handler(makeReq('s1'), res)
  assert.equal(res.statusCode, 200, '围栏放行后必须真的走到截屏，而不是 403')
})

test('passing the fence means "returned undefined", not "service missing"', async () => {
  // 实测行为（dsh-client-connection）：不信任回 403、未认证回 401、**通过则返回 undefined**。
  const { scope, routes } = makeScope({ rejection: undefined })
  let captured = 0
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => { captured += 1; return { kind: 'cancelled' } },
  })
  await routes[0].handler(makeReq('s1'), makeRes())
  assert.equal(captured, 1)
})

test('a refusing fence never reaches the capture', async () => {
  const { scope, routes } = makeScope({ rejection: 403 })
  let captured = 0
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => { captured += 1; return { kind: 'cancelled' } },
  })
  const res = makeRes()
  await routes[0].handler(makeReq('s1'), res)
  assert.equal(captured, 0, '围栏拒绝后不许去截图')
  assert.equal(res.statusCode, 403)
})

test('a missing fence service fails closed', async () => {
  const { scope, routes } = makeScope({ missingFence: true })
  let captured = 0
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => { captured += 1; return { kind: 'cancelled' } },
  })
  const res = makeRes()
  await routes[0].handler(makeReq('s1'), res)
  assert.equal(captured, 0)
  assert.equal(res.statusCode, 403)
})

test('a PNG capture comes back as image/png bytes', async () => {
  // 真写一个小文件，避免用桩把"读不到文件"这条分支测成绿灯
  const dir = mkdtempSync(join(tmpdir(), 'send-image-route-'))
  const png = join(dir, 'shot.png')
  writeFileSync(png, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  const { scope, routes } = makeScope({ rejection: undefined })
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => ({ kind: 'ok', path: png }),
  })
  const res = makeRes()
  await routes[0].handler(makeReq('s1'), res)
  assert.equal(res.statusCode, 200)
  assert.equal(res.headers['content-type'], 'image/png')
  assert.equal(res.headers['cache-control'], 'no-store')
  assert.equal(res.headers['x-dsh-screenshot'], png)
  assert.equal(res.body.length, 8)
})

test('no session means an actionable message, not a capture', async () => {
  const { scope, routes } = makeScope({ rejection: undefined })
  let captured = 0
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => { captured += 1; return { kind: 'cancelled' } },
  })
  const res = makeRes()
  await routes[0].handler(makeReq(''), res)
  assert.equal(captured, 0, '没有会话就别去截屏')
  assert.equal(res.statusCode, 200)
  assert.match(String(res.body), /no-session/)
})
