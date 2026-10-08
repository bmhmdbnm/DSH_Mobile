#!/usr/bin/env node
/**
 * `profile-parity-apply.mjs` 的用例：这个脚本会改**用户本机**的宿主档案，所以它
 * 必须"预演不写盘、写入幂等、内容不同不擅自覆盖、写前有备份"。
 *
 * 全部在临时 `DSH_HOME` 的 fixture 上跑，不碰真实档案。
 *
 *   node --test scripts/dev/profile-parity-apply.test.mjs
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const HERE = dirname(fileURLToPath(import.meta.url))
const APPLY = join(HERE, 'profile-parity-apply.mjs')
const CHECK = join(HERE, 'profile-parity.mjs')

const PICKER = `- id: directory-picker
  name: '@deepseek-ai/dsh-host-directory-picker-auto'
  disabled: true

- insert:
    - id: directory-picker-browse
      name: '@deepseek-ai/dsh-host-directory-picker-browse'
`

const PERMISSION = `- id: permission
  name: "@deepseek-ai/dsh-permission-presets"
  config:
    presets:
      read-only:
        sandbox: read-only
        approval: ask
    defaultPreset: danger-full-access
`

const BASH = `- id: bash-sandbox
  config:
    timeoutMs: 120000
    maxTimeoutMs: 120000
`

function fixture({ desktopPatch = '' } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'parity-apply-'))
  const write = (name, patch) => {
    const dir = join(home, 'profiles', name)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'package.json'), JSON.stringify({
      name: `dsh-profile-${name}`,
      private: true,
      dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'] } },
    }, null, 2))
    writeFileSync(join(dir, 'cordis.patch.yml'), patch)
  }
  write('web', `${PICKER}\n${BASH}\n${PERMISSION}\n`)
  write('desktop', desktopPatch)
  return home
}

function run(home, args) {
  return spawnSync(process.execPath, [args[0] === 'check' ? CHECK : APPLY, ...args.slice(1)], {
    env: { ...process.env, DSH_HOME: home },
    encoding: 'utf8',
  })
}

const apply = (home, args = []) => run(home, ['apply', ...args])
const check = (home, args = []) => run(home, ['check', ...args])
const patchOf = (home, profile) => readFileSync(join(home, 'profiles', profile, 'cordis.patch.yml'), 'utf8')

function withFixture(options, fn) {
  const home = fixture(options)
  try { fn(home) } finally { rmSync(home, { recursive: true, force: true }) }
}

test('预演：说清要补哪些块，但一个字都不写盘', () => {
  withFixture({}, (home) => {
    const before = patchOf(home, 'desktop')
    const r = apply(home)
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.match(r.stdout, /预演/)
    assert.match(r.stdout, /补 directory-picker/)
    assert.match(r.stdout, /补 bash-sandbox/)
    assert.equal(patchOf(home, 'desktop'), before)
    assert.equal(readdirSync(join(home, 'profiles', 'desktop')).filter((f) => f.includes('bak')).length, 0)
  })
})

test('写入：补上缺的块 + 留备份；再跑一次是空操作（幂等）', () => {
  withFixture({}, (home) => {
    const first = apply(home, ['--write'])
    assert.equal(first.status, 0, first.stdout + first.stderr)
    const after = patchOf(home, 'desktop')
    assert.match(after, /- id: bash-sandbox/)
    assert.match(after, /- insert:/)
    assert.equal(readdirSync(join(home, 'profiles', 'desktop')).filter((f) => f.startsWith('cordis.patch.yml.bak-004-apply-')).length, 1)

    const second = apply(home, ['--write'])
    assert.equal(second.status, 0, second.stdout + second.stderr)
    assert.match(second.stdout, /没有要改的/)
    assert.equal(patchOf(home, 'desktop'), after)
  })
})

test('补完之后，对等检查判绿', () => {
  withFixture({}, (home) => {
    assert.equal(check(home).status, 1)
    assert.equal(apply(home, ['--write']).status, 0)
    const r = check(home)
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.match(r.stdout, /功能对等/)
  })
})

test('内容不同：默认拒绝并给 --overwrite 提示，文件不动', () => {
  withFixture({ desktopPatch: `- id: bash-sandbox\n  config:\n    timeoutMs: 120000\n    maxTimeoutMs: 600000\n` }, (home) => {
    const before = patchOf(home, 'desktop')
    const r = apply(home, ['--write'])
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /覆盖 bash-sandbox/)
    assert.match(r.stderr, /--overwrite/)
    assert.equal(patchOf(home, 'desktop'), before)
  })
})

test('--overwrite：就地换掉那一段，不留重复条目', () => {
  withFixture({ desktopPatch: `- id: bash-sandbox\n  config:\n    timeoutMs: 120000\n    maxTimeoutMs: 600000\n` }, (home) => {
    const r = apply(home, ['--write', '--overwrite', '--block', 'bash-sandbox'])
    assert.equal(r.status, 0, r.stdout + r.stderr)
    const after = patchOf(home, 'desktop')
    assert.equal(after.match(/- id: bash-sandbox/g).length, 1)
    assert.match(after, /maxTimeoutMs: 120000/)
    assert.doesNotMatch(after, /600000/)
  })
})

test('--block 只动指定的那一段', () => {
  withFixture({}, (home) => {
    const r = apply(home, ['--write', '--block', 'permission'])
    assert.equal(r.status, 0, r.stdout + r.stderr)
    const after = patchOf(home, 'desktop')
    assert.match(after, /- id: permission/)
    assert.doesNotMatch(after, /bash-sandbox/)
  })
})

test('未知块名 / 档案不存在：退出码 2，且不写盘', () => {
  withFixture({}, (home) => {
    const before = patchOf(home, 'desktop')
    const unknown = apply(home, ['--write', '--block', 'nope'])
    assert.equal(unknown.status, 2, unknown.stdout + unknown.stderr)
    assert.match(unknown.stderr, /未知块名/)
    assert.equal(patchOf(home, 'desktop'), before)

    rmSync(join(home, 'profiles', 'desktop'), { recursive: true, force: true })
    const missing = apply(home, ['--write'])
    assert.equal(missing.status, 2, missing.stdout + missing.stderr)
    assert.match(missing.stderr, /desktop 档案不存在/)
  })
})

test('宿主专属块不会被搬过去（web 的 ui-settings-general 不补进 desktop）', () => {
  withFixture({}, (home) => {
    writeFileSync(join(home, 'profiles', 'web', 'cordis.patch.yml'),
      `${patchOf(home, 'web')}- id: ui-settings-general\n  name: "@deepseek-ai/dsh-client-ui-settings-general"\n  config:\n    welcomeNoticeVersion: 2026-09-28.1\n`)
    const r = apply(home, ['--write'])
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.doesNotMatch(patchOf(home, 'desktop'), /ui-settings-general/)
    // 检查器也不把它算成差异。
    assert.equal(check(home).status, 0, check(home).stdout)
  })
})

test('只有 desktop、没有 web：退出码 2', () => {
  withFixture({}, (home) => {
    rmSync(join(home, 'profiles', 'web'), { recursive: true, force: true })
    const r = apply(home, ['--write'])
    assert.equal(r.status, 2)
    assert.match(r.stderr, /web 档案不存在/)
  })
})

test('写入的临时文件确实落在 fixture 里（没碰真实档案的迹象）', () => {
  withFixture({}, (home) => {
    apply(home, ['--write'])
    assert.ok(existsSync(join(home, 'profiles', 'desktop', 'cordis.patch.yml')))
    assert.ok(!existsSync(join(home, 'profiles', 'desktop', 'cordis.patch.yml.tmp')))
  })
})
