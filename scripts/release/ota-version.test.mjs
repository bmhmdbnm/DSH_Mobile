import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import { beijingStamp, isNewer, planBuildNumber } from './ota-version.mjs'

const CLI = fileURLToPath(new URL('./ota-version.mjs', import.meta.url))

test('构建号是北京时间，与机器所在的时区无关', () => {
  // 2026-10-12 01:03 UTC = 北京时间 09:03；本机时区怎么设都不该影响结果。
  const at = new Date('2026-10-12T01:03:00Z')
  assert.equal(beijingStamp(at), '20261012.0903')
  const output = execFileSync(process.execPath, [CLI, '--now', at.toISOString()], {
    encoding: 'utf8',
    env: { ...process.env, TZ: 'UTC' },
  }).trim()
  assert.equal(output, '20261012.0903', '脚本在 TZ=UTC 下也必须给北京时间')
})

test('跨零点按北京时间换日（UTC 还在前一天）', () => {
  // 北京时间 2026-10-12 00:30 = UTC 2026-10-11 16:30。
  assert.equal(beijingStamp(new Date('2026-10-11T16:30:00Z')), '20261012.0030')
})

test('形状合法：两段、都在 CFBundleVersion 的上限内', () => {
  const stamp = beijingStamp(new Date('2026-10-12T01:03:00Z'))
  const parts = stamp.split('.')
  assert.equal(parts.length, 2, 'CFBundleVersion 允许 1–3 段，这里固定两段')
  for (const part of parts) {
    assert.match(part, /^\d+$/)
    assert.ok(Number(part) <= 4294967295, `${part} 超过 CFBundleVersion 的单段上限`)
  }
})

test('号不比线上新时往前挪：同一分钟发两次也仍然递增', () => {
  const now = new Date('2026-10-12T01:03:00Z') // 20261012.0903
  assert.equal(planBuildNumber({ now }), '20261012.0903', '线上没有号就照现在打')
  assert.equal(planBuildNumber({ now, published: '20261012.0902' }), '20261012.0903')
  assert.equal(planBuildNumber({ now, published: '20261012.0903' }), '20261012.0904',
    '同一个号再发一次要挪一分钟，否则 iOS 静默不装')
  assert.equal(planBuildNumber({ now, published: '20261012.0907' }), '20261012.0908',
    '本机时钟落后于线上时也要比线上大')
  assert.equal(planBuildNumber({ now, published: 'garbage' }), '20261012.0903',
    '线上号读不出来就退回本机时间')
})

test('isNewer 与 iOS 读 CFBundleVersion 的方式一致（逐段按整数比）', () => {
  assert.equal(isNewer('20261012.0903', '20261012.0902'), true)
  assert.equal(isNewer('20261012.0903', '20261012.0903'), false)
  assert.equal(isNewer('20261012.0903', '20261012.1703'), false, '不能按字符串比：09 点发的比 17 点发的旧')
  assert.equal(isNewer('20261012.0903', '20260924.1925'), true)
  assert.equal(isNewer('', '20261012.0903'), false)
  assert.equal(isNewer('20261012.0903', ''), true, '从没有号到有号算更新')
})

test('--read-published 从 version.json 里只取 build，读不到就给空串', () => {
  const run = (input) => execFileSync(process.execPath, [CLI, '--read-published'], {
    encoding: 'utf8', input,
  })
  assert.equal(run('{"shortVersion":"1.0","build":"20261012.0059"}'), '20261012.0059')
  assert.equal(run('not json'), '', '站点返回坏内容时不能把发布卡住')
  assert.equal(run('{"shortVersion":"1.0"}'), '')
})

test('--compare 的退出码就是"iOS 肯不肯装"', () => {
  const run = (a, b) => {
    try {
      execFileSync(process.execPath, [CLI, '--compare', a, b], { stdio: 'ignore' })
      return 0
    } catch (error) {
      return error.status
    }
  }
  assert.equal(run('20261012.0903', '20261012.0902'), 0)
  assert.equal(run('20261012.0903', '20261012.0903'), 1, '同一个号 iOS 不会装')
  assert.equal(run('20261012.0903', '20261012.1703'), 1)
})
