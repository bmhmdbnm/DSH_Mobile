#!/usr/bin/env node
/**
 * 两个宿主档案的**功能对等**检查。
 *
 *   node scripts/dev/profile-parity.mjs            # 有差异即非零退出（默认，用于闸门）
 *   node scripts/dev/profile-parity.mjs --report   # 只报告，始终 0（人工看差异）
 *   node scripts/dev/profile-parity.mjs --json     # 机器可读
 *
 * 为什么需要：官方桌面版用 `profiles/desktop`，命令行 web 版用 `profiles/web`，
 * 两个档案的**插件与配置互相独立**。只在一边做过的事，换宿主就会失效——实测过两次：
 *   1. 只在 web 档案注册的模型提供方（company-gateway）在桌面版里报
 *      "no adapter registered for provider"，手机发消息当场失败；
 *   2. 只在 web 档案挂的 browse 目录后端没跟到桌面版，手机「新建会话」的目录浏览整块失效
 *      （004；根因见 maintainers/VERIFY-004-desktop-host-parity.md）。
 *
 * 检查三类：
 *   1. dependencies（装了哪些插件）
 *   2. dsh.profile.bundles（哪些 bundle 被启用）
 *   3. cordis.patch.yml 的顶层条目：**id 集合 + 规范化内容**
 *
 * 内容比较是"规范化文本比较"：注释、空行、行内多余空白、标量两端的引号都不参与，
 * 顺序参与。这样"改了一个超时值 / 删了一个模型 / 换了默认档"都会报出来，
 * 而纯粹的排版差异不会。刻意不引 YAML 依赖：仓库保持零新增依赖，
 * 而档案是我们自己写的、形状固定（顶层 `- id:` / `- insert:`）。
 *
 * 退出码：0 = 对等；1 = 有差异**或某个档案整个不存在**（`--allow-missing` 可放过后者，
 * 用于只装了单宿主的机器）；2 = 工具自身出错。
 */

import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = process.env.DSH_HOME || join(homedir(), '.dsh')
const PROFILES = { web: join(HOME, 'profiles', 'web'), desktop: join(HOME, 'profiles', 'desktop') }
const asJson = process.argv.includes('--json')
const strict = !process.argv.includes('--report')
const allowMissing = process.argv.includes('--allow-missing')

/**
 * 只属于某一个档案的配置块：不算差异，但**出现在另一边**要报出来。
 *
 * - desktop：官方桌面版启动/保存设置时自己写的客户端设置，web 档案不需要；
 * - web：`ui-settings-general` 的「欢迎公告已确认版本」。owner 2026-10-08 决定不镜像到
 *   桌面版（它的正常归宿是用户点一次「继续」自动记录；见 specs/004-desktop-host-parity/spec.md FR-005）。
 */
const HOST_OWNED = {
  desktop: new Set(['ui-chat', 'ui-settings', 'ui-settings-account']),
  web: new Set(['ui-settings-general']),
}

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return undefined }
}

/** 规范化的内容行：去注释、去空行、去缩进、压缩空白、去标量两端引号。 */
function canonical(lines) {
  const out = []
  for (const raw of lines) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    const collapsed = line.replace(/\s+/g, ' ').replace(/:\s*'([^']*)'$/, ': $1').replace(/:\s*"([^"]*)"$/, ': $1')
    out.push(collapsed)
  }
  return out.join('\n')
}

/**
 * 顶层 patch 条目：`- id: <name>` 与 `- insert:` 各算一条。
 * 缩进的 `- id:`（insert 的子项）不切分。
 */
function patchBlocks(path) {
  if (!existsSync(path)) return []
  const blocks = []
  let current
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (/^- id: /.test(line) || /^- insert:/.test(line)) {
      if (current) blocks.push(current)
      current = { head: line, lines: [line] }
    } else if (current) {
      current.lines.push(line)
    }
  }
  if (current) blocks.push(current)
  return blocks.map((block) => {
    const named = /^- id: (\S+)/.exec(block.head)
    if (named) return { id: named[1], body: canonical(block.lines) }
    const inner = [...block.lines.join('\n').matchAll(/^\s+- id: (\S+)/gm)].map((m) => m[1])
    return { id: `insert(${inner.join(', ')})`, body: canonical(block.lines), insert: true }
  })
}

function profileState(dir) {
  if (!existsSync(join(dir, 'package.json'))) return undefined
  const manifest = readJson(join(dir, 'package.json'))
  return {
    deps: Object.keys(manifest?.dependencies ?? {}),
    bundles: manifest?.dsh?.profile?.bundles ?? [],
    blocks: patchBlocks(join(dir, 'cordis.patch.yml')),
  }
}

const missingProfiles = Object.entries(PROFILES).filter(([, dir]) => !existsSync(join(dir, 'package.json')))
const states = Object.fromEntries(
  Object.entries(PROFILES).map(([name, dir]) => [name, profileState(dir) ?? { deps: [], bundles: [], blocks: [] }]),
)

const findings = []
const hostOwnedSeen = { web: [], desktop: [] }

function setGaps(field, other, mine, side) {
  for (const item of other) {
    if (mine.has(item)) continue
    if (field === 'patches') {
      const owner = Object.keys(HOST_OWNED).find((name) => HOST_OWNED[name].has(item) && name !== side)
      if (owner) { hostOwnedSeen[owner].push(item); continue }
    }
    findings.push({ field, item, missingIn: side, kind: 'missing' })
  }
}

// 只有一个档案时不做比较：另一个没装过该宿主，"缺块"没有意义（整个档案都不在）。
// 但默认仍然判红——档案被整个删掉，是比缺块更严重的一种"对等被破坏"。
if (missingProfiles.length === 0) {
  for (const field of ['deps', 'bundles']) {
    const web = new Set(states.web[field])
    const desktop = new Set(states.desktop[field])
    setGaps(field, web, desktop, 'desktop')
    setGaps(field, desktop, web, 'web')
  }

  {
    const web = new Map(states.web.blocks.map((b) => [b.id, b]))
    const desktop = new Map(states.desktop.blocks.map((b) => [b.id, b]))
    setGaps('patches', web.keys(), new Set(desktop.keys()), 'desktop')
    setGaps('patches', desktop.keys(), new Set(web.keys()), 'web')
    for (const [id, block] of web) {
      const other = desktop.get(id)
      if (other && other.body !== block.body) findings.push({ field: 'patches', item: id, kind: 'drift' })
    }
    // 宿主专属块出现在另一边：不是缺块，是错位，照样要报。
    for (const side of ['web', 'desktop']) {
      const mine = states[side].blocks.map((b) => b.id)
      for (const id of mine) {
        const owner = Object.keys(HOST_OWNED).find((name) => HOST_OWNED[name].has(id))
        if (owner && owner !== side) findings.push({ field: 'patches', item: id, kind: 'misplaced', owner, side })
      }
    }
  }
}

/** 缺块时的修复命令：告诉人往哪个文件贴哪一段、要重启哪个宿主。 */
function fixHint(finding) {
  if (finding.kind === 'missing' && finding.field === 'patches') {
    const from = finding.missingIn === 'desktop' ? 'web' : 'desktop'
    const host = finding.missingIn === 'desktop' ? '官方桌面版（npm run restart）' : 'web 宿主'
    const what = finding.item.startsWith('insert(')
      ? `那条 \`- insert:\`（子项：${finding.item.slice('insert('.length, -1)}）整段`
      : `\`- id: ${finding.item}\` 那一段`
    return `把 ${from} 档案里 ${what}原文复制进 ${finding.missingIn}/cordis.patch.yml，再重启 ${host}`
  }
  if (finding.kind === 'missing' && finding.field === 'deps') {
    const cli = finding.missingIn === 'desktop' ? '应用包里的 dsh（npm 版拒绝管理 desktop 档案）' : 'dsh'
    return `用 ${cli} 把 ${finding.item} 装进 ${finding.missingIn} 档案`
  }
  if (finding.kind === 'missing') {
    return `把 ${finding.item} 加进 ${finding.missingIn} 档案的 dsh.profile.bundles`
  }
  if (finding.kind === 'drift') {
    return `两边的 ${finding.item} 内容不一致：以 web 档案为准覆盖过去（或反之），再重启对应宿主`
  }
  return `${finding.item} 是 ${finding.owner} 档案专属，不该出现在 ${finding.side} 档案里`
}

const ok = findings.length === 0 && (missingProfiles.length === 0 || allowMissing)

if (asJson) {
  process.stdout.write(`${JSON.stringify({ states, findings, missingProfiles: missingProfiles.map(([n]) => n) }, null, 2)}\n`)
} else {
  for (const name of ['web', 'desktop']) {
    const s = states[name]
    const skipped = missingProfiles.some(([n]) => n === name)
    process.stdout.write(`${name}: ${skipped ? '档案不存在（跳过）' : `插件 ${s.deps.length} · bundle ${s.bundles.length} · 配置块 ${s.blocks.length}`}\n`)
  }
  process.stdout.write('\n')
  if (hostOwnedSeen.desktop.length) {
    process.stdout.write(`宿主专属配置块（不算差异）：${[...new Set(hostOwnedSeen.desktop)].join(', ')}\n—— 官方桌面版自己写的客户端设置，web 档案不需要。\n\n`)
  }
  if (hostOwnedSeen.web.length) {
    process.stdout.write(`宿主专属配置块（不算差异）：${[...new Set(hostOwnedSeen.web)].join(', ')}\n—— 只属于 web 档案，桌面版不需要（owner 2026-10-08 决定）。\n\n`)
  }
  if (ok) {
    process.stdout.write('两个档案功能对等：插件、bundle、配置块三类一致（含关键内容）。\n')
  } else {
    if (findings.length) {
      process.stdout.write(`差异 ${findings.length} 处：\n`)
      for (const f of findings) {
        const where = f.kind === 'missing' ? `缺少：${f.missingIn}` : f.kind === 'drift' ? '内容漂移' : `错位：不该在 ${f.side}`
        process.stdout.write(`  [${f.field}] ${f.item}  ← ${where}\n`)
      }
      process.stdout.write('\n对齐做法：\n')
      for (const f of findings) process.stdout.write(`  · ${f.item}：${fixHint(f)}\n`)
    }
    if (missingProfiles.length) {
      process.stdout.write(`跳过的档案：${missingProfiles.map(([n]) => `${n}（没装过该宿主）`).join('、')}——对等检查只在两个档案都存在时有意义。\n`)
    }
  }
}

process.exitCode = strict && !ok ? 1 : 0
