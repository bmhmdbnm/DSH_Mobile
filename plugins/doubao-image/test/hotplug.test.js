/**
 * 热插拔契约（003）：这个插件在宿主里只该挂一个工具，而且"禁用即撤干净、再启用原样回来"。
 *
 * 官方 tools 服务把 `register` 绑在当前 fiber 上（宿主禁用插件时由它撤销），所以这里的 stub
 * 把 register 的 disposer 收起来，在测试里手动跑一遍——正是宿主那条路径的镜像。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import * as plugin from '../lib/index.js'

function fakeContext() {
  const tools = []
  const disposers = []
  const ctx = {
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    tools: {
      register(definition) {
        tools.push(definition)
        const dispose = () => {
          const index = tools.indexOf(definition)
          if (index >= 0) tools.splice(index, 1)
        }
        disposers.push(dispose)
        return dispose
      },
    },
  }
  return { ctx, tools, disposers }
}

test('it declares the services it needs and nothing else', () => {
  assert.deepEqual([...plugin.inject], ['tools', 'attachments'])
})

test('applying it registers exactly one tool and writes nothing global', () => {
  const before = new Set(Object.keys(globalThis))
  const { ctx, tools } = fakeContext()
  plugin.apply(ctx)
  assert.deepEqual(tools.map((tool) => tool.name), ['generate_image'])
  assert.equal(typeof tools[0].execute, 'function')
  assert.deepEqual(Object.keys(globalThis).filter((key) => !before.has(key)), [],
    'apply 不许往 globalThis 写东西（那是热插拔泄漏的第一来源）')
})

test('disable then enable three times restores exactly one tool each round', () => {
  for (let round = 1; round <= 3; round += 1) {
    const { ctx, tools, disposers } = fakeContext()
    plugin.apply(ctx)
    assert.equal(tools.length, 1, `第 ${round} 轮启用：1 个工具`)
    for (const dispose of disposers) dispose()
    assert.equal(tools.length, 0, `第 ${round} 轮禁用：工具归零`)
    assert.doesNotThrow(() => { for (const dispose of disposers) dispose() }, '重复撤销必须是安全的')
  }
})

test('applying it never throws (a failure here would take the whole boot audit down)', () => {
  const { ctx } = fakeContext()
  assert.doesNotThrow(() => plugin.apply(ctx))
})
