/**
 * 这条检查必须真的能抓到那两类缺陷——不然它只是给人看的绿灯。
 * 用合成输入验两个判据：模块顶层定时器、客户端 bundle 能不能重入。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { firstCodeLine, startsWithDeclaration, stripComments, topLevelTimers } from './check-plugin-hotplug.mjs'

test('a timer at module scope is reported, an indented one inside a function is not', () => {
  const bad = [
    "import { x } from './x.js'",
    'const heartbeat = setInterval(() => ping(), 15000)',
    'export const poller = setTimeout(tick, 1000)',
    'setInterval(tick, 1000)',
  ].join('\n')
  assert.deepEqual(topLevelTimers(bad).map((finding) => finding.line), [2, 3, 4])

  const good = [
    'function start() {',
    '  const heartbeat = setInterval(() => ping(), 15000)',
    '  return () => clearInterval(heartbeat)',
    '}',
    // 顶层声明的工具函数里调定时器不算泄漏：没有句柄留在模块上
    'export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))',
  ].join('\n')
  assert.deepEqual(topLevelTimers(good), [], '函数体里的定时器只要给得出清理函数就不算泄漏')
})

test('a client bundle starting with a top-level declaration is rejected', () => {
  // 这正是 002 的缺陷：整份脚本没套 IIFE，第二次执行会 "Identifier … has already been declared"。
  const unwrapped = [
    '/** 文档注释 */',
    "const ROUTE = 'send-image/screenshot'",
    'window.__ModuleLoader__.load({ id: "x", factory: () => ({}) })',
  ].join('\n')
  assert.equal(startsWithDeclaration(unwrapped), true)

  const iife = [
    '/** 文档注释 */',
    ';(() => {',
    "const ROUTE = 'send-image/screenshot'",
    'window.__ModuleLoader__.load({ id: "x", factory: () => ({}) })',
    '})()',
  ].join('\n')
  assert.equal(startsWithDeclaration(iife), false, '套了 IIFE 就与官方 bundle 同形')

  // 官方的写法也可以：顶层只有那一句 load()，声明都在 factory 里
  const official = 'window.__ModuleLoader__.load({ id: "y", factory: (require) => ({}) })'
  assert.equal(startsWithDeclaration(official), false)
})

test('comments never decide the verdict', () => {
  const commented = '/* const ROUTE = 1 */\n// const OTHER = 2\nwindow.__ModuleLoader__.load({})'
  assert.equal(firstCodeLine(commented).startsWith('window.'), true)
  assert.equal(startsWithDeclaration(commented), false)
  assert.equal(stripComments('const a = 1 // 注释\n/* 块 */\nconst b = 2').includes('const b'), true)
})
