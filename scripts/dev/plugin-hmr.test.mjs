/**
 * `scripts/dev/plugin-hmr.mjs` 的用例。
 *
 * 这个脚本改的是**用户档案**（`~/.dsh/profiles/<profile>/cordis.patch.yml`），改错了会把插件树弄坏，
 * 所以它自己必须被守着：幂等、不误删别人的条目、别人的 hmr 条目一律不覆盖。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { blockRoots, applyOff, applyOn, findHmrBlock, hmrBlock, statusOf } from './plugin-hmr.mjs'

const ROOT = '/Users/someone/repo/plugins'

test('on 追加一块，内容不被改写，status 变 on', () => {
  const before = '# 用户自己的层\n- id: ui-settings\n  config:\n    enabled: true\n'
  const { text, changed } = applyOn(before, ROOT)
  assert.equal(changed, true)
  assert.ok(text.startsWith(before), '原有内容必须一字不动地留在前面')
  assert.equal(statusOf(text, ROOT), 'on')
  const block = findHmrBlock(text)
  assert.deepEqual(blockRoots(block.lines.slice(block.start, block.end)), [ROOT])
})

test('on 幂等：连开两次只有一块', () => {
  const once = applyOn('- id: ui-chat\n', ROOT).text
  const twice = applyOn(once, ROOT)
  assert.equal(twice.changed, false)
  assert.equal(twice.text, once)
  assert.equal(once.split('- id: hmr').length - 1, 1)
})

test('别人的 hmr 条目不被覆盖，报冲突', () => {
  const foreign = '- id: hmr\n  config:\n    root: ["/somewhere/else"]\n'
  const result = applyOn(foreign, ROOT)
  assert.equal(result.conflict, true)
  assert.equal(result.text, foreign)
  assert.deepEqual(result.roots, ['/somewhere/else'])
  assert.equal(statusOf(foreign, ROOT), 'other')
})

test('off 只删自己那块（连同标记与空行），别人的条目与上文一字不动', () => {
  const mine = '# 用户自己的层\n- id: ui-settings\n  config:\n    enabled: true\n'
  const on = applyOn(mine, ROOT).text
  const { text, changed } = applyOff(on, ROOT)
  assert.equal(changed, true)
  assert.equal(text, mine)
  assert.equal(statusOf(text, ROOT), 'off')
})

test('off 幂等，且不动指向别处的 hmr 条目', () => {
  const mine = applyOn('- id: ui-chat\n', ROOT).text
  const once = applyOff(mine, ROOT).text
  assert.equal(applyOff(once, ROOT).changed, false)
  const foreign = '- id: hmr\n  config:\n    root: ["/somewhere/else"]\n'
  assert.equal(applyOff(foreign, ROOT).foreign, true)
  assert.equal(applyOff(foreign, ROOT).text, foreign)
})

test('YAML 列表写法与内联写法都能读出来', () => {
  const list = '- id: hmr\n  config:\n    root:\n      - /a\n      - /b\n'
  const inline = '- id: hmr\n  config:\n    root: ["/a", "/b"]\n'
  for (const text of [list, inline]) {
    const block = findHmrBlock(text)
    assert.deepEqual(blockRoots(block.lines.slice(block.start, block.end)), ['/a', '/b'])
  }
})

test('hmrBlock 写出的块能被 findHmrBlock 读回', () => {
  const text = `- id: ui-chat\n${hmrBlock(ROOT)}`
  assert.equal(statusOf(text, ROOT), 'on')
})
