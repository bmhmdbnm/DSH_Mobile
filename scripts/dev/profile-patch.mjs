/**
 * `cordis.patch.yml` 的最小解析：顶层条目、规范化内容、宿主专属块登记。
 *
 * 只被两个开发脚本用（`profile-parity.mjs` 检查、`profile-parity-apply.mjs` 对齐），
 * 所以放在这里共享——解析规则只有一份，检查与对齐不会各理解一套。
 *
 * 刻意不引 YAML 依赖：档案形状固定（顶层 `- id:` / `- insert:`，缩进的两层），
 * 而且仓库的检查脚本保持零新增依赖。
 */

import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

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

/** 规范化的内容行：去注释、去空行、去缩进、压缩空白、去标量两端引号。 */
export function canonical(lines) {
  const out = []
  for (const raw of lines) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    out.push(line
      .replace(/\s+/g, ' ')
      .replace(/:\s*'([^']*)'$/, ': $1')
      .replace(/:\s*"([^"]*)"$/, ': $1'))
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
