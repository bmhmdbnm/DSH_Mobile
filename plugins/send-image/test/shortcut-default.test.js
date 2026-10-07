import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/**
 * 默认热键的两条硬约束（宪法原则 I：能机械判定的缺陷不许留给慢闸）。
 *
 * 第一版 002 用 ⌥⌘A，和官方 `session.archive` 的 web 默认键撞车，注册表在注册时抛
 * `Conflicting shortcut defaults`，异常落在**后注册的官方插件**上，整个界面起不来。这条用例就是
 * 那个缺陷的快闸：把我们的默认键与"已安装的官方 bundle 里声明过的默认键"做交集，非空即红。
 *
 * 官方默认键集合从本机已安装的官方客户端 bundle 里抽（`code:` + `modifiers:` 字面量，以及
 * workpace 那种位置参数注册）。找不到安装目录时**跳过**并说明原因——这条用例的价值在开发机与
 * 装过 DSH 的机器上，不靠它给干净 CI 发绿灯。
 */

const CLIENT_SOURCE = readFileSync(new URL('../lib/client.js', import.meta.url), 'utf8')

/** 从自己的客户端半边里读出声明出去的默认键（唯一真源）。 */
export function declaredHotkey(source = CLIENT_SOURCE) {
  const match = source.match(/const HOTKEY = \{ code: '([^']+)', modifiers: \[([^\]]*)\] \}/)
  assert.ok(match, 'lib/client.js 里应当有一处 HOTKEY 声明')
  return {
    code: match[1],
    modifiers: [...match[2].matchAll(/'([^']+)'/g)].map((item) => item[1]),
  }
}

/** 官方规则的镜像：web 运行时哪些组合被允许（`isWebBindingAllowed`）。 */
export function webBindingAllowed({ code, modifiers }, platform = 'macos') {
  const primary = platform === 'macos' ? 'meta' : 'control'
  const mods = modifiers.map((modifier) => (modifier === 'primary' ? primary : modifier))
  if (mods.length >= 3) return true
  if (mods.length === 2 && mods.includes(primary) && (mods.includes('alt') || mods.includes('shift'))) return true
  const single = mods.length === 1 && mods[0] === primary
  return single && ['Comma', 'Backslash', 'Slash'].includes(code)
}

/** 官方规则的镜像：系统/编辑器/浏览器的保留组合（`bindingIssue` 的 reserved 分支）。 */
export function isReserved({ code, modifiers }, platform = 'macos') {
  const mods = modifiers.map((modifier) => (modifier === 'primary' ? (platform === 'macos' ? 'meta' : 'control') : modifier))
  const primary = mods.includes(platform === 'macos' ? 'meta' : 'control')
  if (['Escape', 'Tab', 'Space', 'Backspace', 'Delete'].includes(code)) return true
  if (primary && ['KeyC', 'KeyV', 'KeyX', 'KeyZ', 'KeyY', 'KeyQ', 'KeyH'].includes(code)) return true
  if (primary && code === 'KeyA' && !mods.includes('shift')) return true
  if (platform === 'macos' && mods.includes('control') && mods.includes('meta')) return true
  if (platform === 'macos' && mods.includes('alt') && !primary) return true
  return false
}

/** 本机已安装的官方客户端 bundle 目录；找不到返回 null。 */
function officialBundleDirs() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  const roots = [
    process.env.DSH_INSTALL_DIR ? join(process.env.DSH_INSTALL_DIR, 'node_modules', '@deepseek-ai') : null,
    join(home, 'profiles', 'node_modules', '@deepseek-ai'),
    join(home, 'profiles', 'web', 'node_modules', '@deepseek-ai'),
  ].filter(Boolean)
  const dirs = []
  for (const root of roots) {
    if (!existsSync(root)) continue
    for (const name of readdirSync(root)) {
      const client = join(root, name, 'lib', 'client.js')
      if (existsSync(client)) dirs.push(client)
    }
  }
  return dirs
}

/** 官方 bundle 里声明过的默认键（无论哪个 profile，保守取并集）。 */
function officialBindings(dirs) {
  const found = new Set()
  const add = (code, modifiers) => {
    const normalized = [...modifiers].sort().join('+')
    found.add(`${code}|${normalized}`)
  }
  for (const file of dirs) {
    const text = readFileSync(file, 'utf8')
    // 对象形式：defaults: { "web:macos": { code: "KeyA", modifiers: [...] } }
    for (const match of text.matchAll(/code:\s*"([A-Za-z0-9]+)"\s*,\s*modifiers:\s*\[([^\]]*)\]/g)) {
      add(match[1], [...match[2].matchAll(/"([^"]+)"/g)].map((item) => item[1]))
    }
    // 位置参数形式（工作区那种）：register(id, label, aliases, "KeyA", [桌面修饰键], [web 修饰键], run)
    for (const match of text.matchAll(/"([\w.\-]+)"[^,]*,[^,]*,\s*\[[^\]]*\],\s*"([A-Za-z0-9]+)",\s*(\[[^\]]*\]),\s*(\[[^\]]*\])/g)) {
      for (const group of [match[3], match[4]]) {
        add(match[2], [...group.matchAll(/"([^"]+)"/g)].map((item) => item[1]))
      }
    }
  }
  return found
}

const BUNDLES = officialBundleDirs()
const SKIP_REASON = BUNDLES.length === 0
  ? '本机没有找到已安装的官方 DSH bundle（DSH_HOME / DSH_INSTALL_DIR），跳过与官方默认键的交集检查'
  : false

test('the declared default passes the web-runtime binding rules', () => {
  const hotkey = declaredHotkey()
  assert.equal(isReserved(hotkey), false, `${hotkey.code} 落在官方保留组合里`)
  assert.equal(webBindingAllowed(hotkey), true, '默认键必须能在 web 运行时绑定')
  assert.equal(webBindingAllowed(hotkey, 'windows'), true, 'Windows 下同样要能绑定')
})

test('the declared default does not collide with any official default', { skip: SKIP_REASON }, () => {
  const hotkey = declaredHotkey()
  const taken = officialBindings(BUNDLES)
  assert.ok(taken.size > 10, `官方默认键集合看起来太小（${taken.size} 条），抽取规则可能失效`)
  const mine = `${hotkey.code}|${[...hotkey.modifiers].sort().join('+')}`
  assert.equal(taken.has(mine), false,
    `${mine} 已被官方默认键占用：${[...taken].filter((item) => item.startsWith(`${hotkey.code}|`)).join(', ')}`)
})
