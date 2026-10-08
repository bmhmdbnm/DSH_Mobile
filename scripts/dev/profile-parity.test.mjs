#!/usr/bin/env node
/**
 * `profile-parity.mjs` 的用例：这条检查必须**会判红**，否则它只是打印绿灯的摆设。
 *
 * 每个用例都在临时 `DSH_HOME` 里现搭两个档案（fixture），spawn 真脚本，按退出码与输出断言。
 * 覆盖：全一致 → 绿；缺块 → 红；内容漂移 → 红；排版差异 → 不红；宿主专属块错位 → 红；
 *      官方桌面版把档案重置成它自己的默认（我们的块全没了）→ 红；
 *      只装单宿主 → 红，`--allow-missing` 放行；`--report` 只报告。
 *
 *   node --test scripts/dev/profile-parity.test.mjs
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), 'profile-parity.mjs')

/** 官方桌面版自己写的那三段（宿主专属）。 */
const DESKTOP_OWNED = `- id: ui-chat
  name: "@deepseek-ai/dsh-client-ui-chat"
  config:
    transcriptView: standard
`

const PICKER = `# 注释不参与内容比较
- id: directory-picker
  name: '@deepseek-ai/dsh-host-directory-picker-auto'
  disabled: true

- insert:
    - id: directory-picker-browse
      name: '@deepseek-ai/dsh-host-directory-picker-browse'
    - id: directory-picker-browse-ui
      name: '@deepseek-ai/dsh-client-ui-directory-picker-browse'
`

const BASH = `- id: bash-sandbox
  config:
    timeoutMs: 120000
    maxTimeoutMs: 120000
`

/** 一个不属于任何豁免、两边都必须有的普通块。 */
const PLAIN = `- id: hmr
  config:
    root: []
`

/** 只属于 web 档案的块（owner 2026-10-08 决定：欢迎公告的已确认版本不镜像）。 */
const WELCOME = `- id: ui-settings-general
  name: "@deepseek-ai/dsh-client-ui-settings-general"
  config:
    welcomeNoticeVersion: 2026-09-28.1
`

function fixture({ skipDesktop = false, skipWeb = false } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'parity-'))
  const write = (name, patch) => {
    const dir = join(home, 'profiles', name)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'package.json'), JSON.stringify({
      name: `dsh-profile-${name}`,
      private: true,
      dependencies: { 'dsh-plugin-mobile-link': 'link:/x' },
      dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'] } },
    }, null, 2))
    writeFileSync(join(dir, 'cordis.patch.yml'), patch)
  }
  if (!skipWeb) write('web', `${PICKER}\n${BASH}\n${WELCOME}\n`)
  if (!skipDesktop) write('desktop', `${DESKTOP_OWNED}\n${PICKER}\n${BASH}\n`)
  return home
}

function run(home, args = []) {
  return spawnSync(process.execPath, [SCRIPT, ...args], {
    env: { ...process.env, DSH_HOME: home },
    encoding: 'utf8',
  })
}

function patchPath(home, profile) {
  return join(home, 'profiles', profile, 'cordis.patch.yml')
}

function readPatch(home, profile) {
  return readFileSync(patchPath(home, profile), 'utf8')
}

/** 每个用例自己收尾（fixture 在临时目录，不留痕）。 */
function withFixture(options, fn) {
  const home = fixture(options)
  try { fn(home) } finally { rmSync(home, { recursive: true, force: true }) }
}

test('全一致：exit 0，且说明两边对等', () => {
  withFixture({}, (home) => {
    const r = run(home)
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.match(r.stdout, /功能对等/)
    assert.doesNotMatch(r.stdout, /差异 \d+ 处/)
  })
})

test('缺块：desktop 少了 hmr → exit 1，指名缺在哪一边并给修复命令', () => {
  withFixture({}, (home) => {
    writeFileSync(patchPath(home, 'web'), `${readPatch(home, 'web')}\n- id: hmr\n  config:\n    root: []\n`)
    const r = run(home)
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /\[patches\] hmr {2}← 缺少：desktop/)
    assert.match(r.stdout, /复制进 desktop\/cordis\.patch\.yml/)
  })
})

test('豁免不是沉默：bundle 层提供与"按需写入"的块会各自列出来', () => {
  withFixture({}, (home) => {
    // desktop 去掉 picker（它由 mobile-link 的 bundle patch 提供）、web 再加一段按需写入的 permission。
    writeFileSync(patchPath(home, 'desktop'), `${DESKTOP_OWNED}\n${BASH}\n`)
    writeFileSync(patchPath(home, 'web'), `${readPatch(home, 'web')}\n- id: permission\n  config:\n    defaultPreset: danger-full-access\n`)
    const r = run(home)
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.match(r.stdout, /由插件 bundle 层提供（不算差异）：directory-picker/)
    assert.match(r.stdout, /按需写入（不算差异）：permission/)
    assert.match(r.stdout, /功能对等/)
  })
})

test('豁免只认登记过的 id：换个没登记的块照样判红', () => {
  withFixture({}, (home) => {
    writeFileSync(patchPath(home, 'web'), `${readPatch(home, 'web')}\n${PLAIN}`)
    const r = run(home)
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /\[patches\] hmr {2}← 缺少：desktop/)
  })
})

test('内容漂移：同一个块里超时值不同 → exit 1，报"内容漂移"', () => {
  withFixture({}, (home) => {
    writeFileSync(patchPath(home, 'desktop'), readPatch(home, 'desktop').replace('maxTimeoutMs: 120000', 'maxTimeoutMs: 600000'))
    const r = run(home)
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /\[patches\] bash-sandbox {2}← 内容漂移/)
    assert.match(r.stdout, /以 web 档案为准/)
  })
})

test('规范化比较：只差注释、引号与行内空白不算差异', () => {
  withFixture({}, (home) => {
    const drifted = readPatch(home, 'desktop')
      .replace("name: '@deepseek-ai/dsh-host-directory-picker-auto'", 'name: "@deepseek-ai/dsh-host-directory-picker-auto"')
      .replace('    timeoutMs: 120000', '    # 排版差异\n    timeoutMs:    120000')
    writeFileSync(patchPath(home, 'desktop'), drifted)
    const r = run(home)
    assert.equal(r.status, 0, r.stdout + r.stderr)
  })
})

test('宿主专属块错位：web 档案里出现 ui-chat → exit 1', () => {
  withFixture({}, (home) => {
    writeFileSync(patchPath(home, 'web'), `${readPatch(home, 'web')}\n${DESKTOP_OWNED}`)
    const r = run(home)
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /ui-chat {2}← 错位：不该在 web/)
  })
})

test('官方桌面版把档案重置成自己的默认（我们的块全没了）→ exit 1', () => {
  withFixture({}, (home) => {
    writeFileSync(patchPath(home, 'desktop'), DESKTOP_OWNED)
    const r = run(home)
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /bash-sandbox {2}← 缺少：desktop/)
    // picker 那对由 bundle 层提供，所以这里不该再报它（豁免要看得见地豁免）。
    assert.doesNotMatch(r.stdout, /directory-picker {2}← 缺少：desktop/)
    assert.match(r.stdout, /由插件 bundle 层提供（不算差异）：directory-picker/)
  })
})

test('只装单宿主：默认 exit 1（档案整个没了也要看得见），--allow-missing 放行', () => {
  withFixture({ skipDesktop: true }, (home) => {
    const strict = run(home)
    assert.equal(strict.status, 1, strict.stdout + strict.stderr)
    assert.match(strict.stdout, /desktop: 档案不存在（跳过）/)
    assert.doesNotMatch(strict.stdout, /缺少：desktop/)

    const lenient = run(home, ['--allow-missing'])
    assert.equal(lenient.status, 0, lenient.stdout + lenient.stderr)
  })
})

test('--report 只报告不判红；--json 给机器可读结果', () => {
  withFixture({ skipDesktop: true }, (home) => {
    const report = run(home, ['--report'])
    assert.equal(report.status, 0, report.stdout + report.stderr)
    assert.match(report.stdout, /跳过/)

    const json = run(home, ['--json', '--report'])
    assert.equal(json.status, 0, json.stdout + json.stderr)
    assert.deepEqual(JSON.parse(json.stdout).missingProfiles, ['desktop'])
  })
})
