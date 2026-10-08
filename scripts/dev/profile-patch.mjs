/**
 * `cordis.patch.yml` 的最小解析：顶层条目、规范化内容、宿主专属块登记。
 *
 * 只被两个开发脚本用（`profile-parity.mjs` 检查、`profile-parity-apply.mjs` 对齐），
 * 所以放在这里共享——解析规则只有一份，检查与对齐不会各理解一套。
 *
 * 刻意不引 YAML 依赖：档案形状固定（顶层 `- id:` / `- insert:`，缩进的两层），
 * 而且仓库的检查脚本保持零新增依赖。
 */

import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** 本文件在 `<repo>/scripts/dev/` 下，仓库根是上两级。 */
function defaultRepoRoot() {
  return join(dirname(fileURLToPath(import.meta.url)), '..', '..')
}

/** 默认数据根（`DSH_HOME` 优先，便于隔离测试）。 */
export function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

/** 某个宿主档案目录。 */
export function profileDir(name, home = dshHome()) {
  return join(home, 'profiles', name)
}

/**
 * 只属于某一个档案的配置块：不算差异，但**出现在另一边**要报出来。
 *
 * - desktop：官方桌面版启动/保存设置时自己写的客户端设置，web 档案不需要；
 * - web：`ui-settings-general` 的「欢迎公告已确认版本」。owner 2026-10-08 决定不镜像到
 *   桌面版（它的正常归宿是用户点一次「继续」自动记录）。
 */
export const HOST_OWNED = {
  desktop: new Set(['ui-chat', 'ui-settings', 'ui-settings-account']),
  web: new Set(['ui-settings-general']),
}

/**
 * 由**仓库里我们自己的插件**在 bundle 层提供的顶层条目 id：
 * bundle 层在两个档案里都装着同一个包，所以这些条目天然对等，档案里没有不算缺。
 *
 * 从 `plugins/<pkg>/cordis.patch.yml` 现读现算，不写死清单——否则清单会和插件漂移
 * （004：`directory-picker` / browse 那一对就是由 `dsh-plugin-mobile-link` 的 bundle patch 声明的）。
 *
 * @param repoRoot 仓库根目录（默认从本文件位置推两级）。
 * @returns 条目 id 集合（含 `insert(...)` 这种合成 id）。
 */
export function bundleProvidedIds(repoRoot = defaultRepoRoot()) {
  const ids = new Set()
  const pluginsDir = join(repoRoot, 'plugins')
  let names = []
  try { names = readdirSync(pluginsDir) } catch { return ids }
  for (const name of names) {
    const dir = join(pluginsDir, name)
    let manifest
    try { manifest = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) } catch { continue }
    const declared = manifest?.dsh?.bundle?.patch
    const files = typeof declared === 'string' ? [declared] : Array.isArray(declared) ? declared : []
    for (const file of files) {
      // 相对路径的锚点在这个文件旁边（与 DSH 的 loadOverlayPatches 一致）。
      for (const block of parseBlocks(readPatch(join(dir, file)))) ids.add(block.id)
    }
  }
  return ids
}

/**
 * 由使用者**按需**写入的条目：两边不必都预置，缺了不算差异。
 *
 * owner 2026-10-08 决定：`permission.defaultPreset` 与 `agent-default-model` 不写死在档案里，
 * 以后在手机设置页点选即可（写进去的就是同一个 profile patch，ConfigEditor 就地编辑）。
 * 这里登记的是"缺了不是故障"，不是"永远不管"——它们的内容一旦两边都有，仍然会比内容。
 */
export const ON_DEMAND = new Set(['permission', 'agent-default-model'])

/**
 * 规范化的内容行。不参与比较的：注释、空行、缩进、行内多余空白、标量两端的引号、
 * 流式序列/映射的括号内空白，以及**顶层 `name:`**（那是条目身份：同一个 id 在不同档案里
 * 可以带 `name` 也可以不带，模块名由 id 决定；insert 子项里的 `name` 是内容，保留）。
 */
export function canonical(lines) {
  const out = []
  for (const raw of lines) {
    // 行级 `name:`（缩进 ≤2）是条目身份，不是内容；insert 子项里的 `name:`（缩进 6）是内容。
    const indent = raw.length - raw.trimStart().length
    if (indent <= 2 && /^name:\s/.test(raw.trimStart())) continue
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    out.push(line
      .replace(/\s+/g, ' ')
      .replace(/:\s*'([^']*)'$/, ': $1')
      .replace(/:\s*"([^"]*)"$/, ': $1')
      .replace(/\[\s+/g, '[')
      .replace(/\s+\]/g, ']')
      .replace(/{\s+/g, '{')
      .replace(/\s+}/g, '}')
      .replace(/,\s+/g, ','))
  }
  return out.join('\n')
}

export function readPatch(path) {
  return existsSync(path) ? readFileSync(path, 'utf8') : ''
}

/**
 * 顶层 patch 条目：`- id: <name>` 与 `- insert:` 各算一条。
 * 缩进的 `- id:`（insert 的子项）不切分。
 *
 * @returns {Array<{id: string, insert: boolean, lines: string[], start: number, end: number}>}
 *   `start` / `end` 是行下标（`end` 不含），给"就地替换某一段"用。
 */
export function parseBlockRanges(text) {
  const lines = text.split('\n')
  const ranges = []
  let current
  lines.forEach((line, index) => {
    if (/^- id: /.test(line) || /^- insert:/.test(line)) {
      if (current) ranges.push({ ...current, end: index })
      current = { lines: [line], start: index }
    } else if (current) {
      current.lines.push(line)
    }
  })
  if (current) ranges.push({ ...current, end: lines.length })

  return ranges.map((range) => {
    const named = /^- id: (\S+)/.exec(range.lines[0])
    if (named) return { ...range, id: named[1], insert: false }
    const inner = [...range.lines.join('\n').matchAll(/^\s+- id: (\S+)/gm)].map((m) => m[1])
    return { ...range, id: `insert(${inner.join(', ')})`, insert: true }
  })
}

/**
 * 顶层条目 + 规范化内容。
 *
 * @returns {Array<{id: string, text: string, body: string, insert: boolean}>}
 */
export function parseBlocks(text) {
  return parseBlockRanges(text).map((range) => ({
    id: range.id,
    insert: range.insert,
    text: range.lines.join('\n').trimEnd(),
    body: canonical(range.lines),
  }))
}

/** 一个档案的全部顶层条目（档案不存在时返回空数组）。 */
export function blocksOf(path) {
  return parseBlocks(readPatch(path))
}

/** 顶层条目 id 列表（给需要"只比 id"的地方用）。 */
export function blockIds(text) {
  return parseBlocks(text).map((b) => b.id)
}

/** 便于人类阅读的档案名对：`web` / `desktop`。 */
export const PROFILE_NAMES = ['web', 'desktop']
