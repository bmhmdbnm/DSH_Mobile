#!/usr/bin/env node
// 从探针落盘里算"翻历史"的体验指标（spec 007 T047）。
//
// 口径（都只依赖 `detail/probe.log` 里已有的行，不额外插桩）：
//   * 等待时长 = 视口真的到顶（`older.drive phase=at-top`）或进入余量带（`prefetch.near`）
//     到该页落地（`older.pump`）的间隔——用"到顶"而不是"开始送"是因为后者还包含驱动自己的
//     500ms 稳定等待，会把数字抬高一截；
//   * 可见等待比例 = 这些等待之和 / 从第一次触发到最后一次落地的总时长；
//   * 单次上限 = 最长的一次等待；
//   * kept 比例 = `older.pump kept=1` 占全部 pump 的比例（"补页时读者位置有没有被顶走"）；
//   * 取消 = `prefetch.cancel` 的条数与原因分布。
//
// 用法：node scripts/dev/transcript-paging-stats.mjs [--file <probe.log>] [--json]
//       （不给 --file 时取 test/runs 下最新一份）

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

function latestProbeLog() {
  const root = 'test/runs'
  const runs = readdirSync(root)
    .map((name) => ({ name, at: statSync(join(root, name)).mtimeMs }))
    .sort((a, b) => b.at - a.at)
  for (const run of runs) {
    const file = join(root, run.name, 'detail', 'probe.log')
    try {
      statSync(file)
      return file
    } catch {}
  }
  throw new Error('test/runs 下找不到 detail/probe.log')
}

export function parseProbeLog(text) {
  const events = []
  for (const line of text.split('\n')) {
    const match = line.match(/^([\d.]+)\s+(\S+)\s*(.*)$/)
    if (!match) continue
    const [, at, name, rest] = match
    const fields = {}
    for (const piece of rest.split(/\s+/)) {
      const [key, ...value] = piece.split('=')
      if (key && value.length > 0) fields[key] = value.join('=')
    }
    events.push({ at: Number(at), name, fields })
  }
  return events
}

export function summarise(events) {
  const triggers = events.filter(
    (e) => e.name === 'prefetch.near' || (e.name === 'older.drive' && e.fields.phase === 'at-top'),
  )
  // 首屏时间：进程起来（第一条探针）到第一次真的画出内容。
  const opened = events.find((e) => e.name === 'content' && Number(e.fields.items) > 0)
  const openMs = opened !== undefined && events[0] !== undefined
    ? Math.round((opened.at - events[0].at) * 1000)
    : null
  const pages = events.filter((e) => e.name === 'older.pump')
  const cancels = events.filter((e) => e.name === 'prefetch.cancel')
  const prefetchNear = events.filter((e) => e.name === 'prefetch.near')
  const waits = []
  // 每个触发等它后面第一页落地；触发晚于该页落地的那种（驱动先到顶、页面随后才到）也算。
  for (const trigger of triggers) {
    const page = pages.find((p) => p.at >= trigger.at)
    if (page) waits.push(page.at - trigger.at)
  }
  const first = triggers[0]?.at ?? pages[0]?.at ?? 0
  const last = pages[pages.length - 1]?.at ?? first
  const span = Math.max(last - first, 0.001)
  const kept = pages.filter((p) => p.fields.kept === '1').length
  return {
    pages: pages.length,
    waits,
    waitTotal: waits.reduce((sum, value) => sum + value, 0),
    span,
    visibleWaitRatio: waits.reduce((sum, value) => sum + value, 0) / span,
    maxWait: waits.length > 0 ? Math.max(...waits) : 0,
    keptRatio: pages.length > 0 ? kept / pages.length : null,
    prefetchNear: prefetchNear.length,
    cancels: cancels.map((c) => c.fields.reason ?? 'unknown'),
    openMs,
    firstAt: first,
  }
}

function report(result, file) {
  const lines = []
  lines.push(`探针文件：${file}`)
  lines.push(`补页次数：${result.pages}`)
  lines.push(
    `等待：合计 ${result.waitTotal.toFixed(2)}s / 跨度 ${result.span.toFixed(2)}s` +
      ` ⇒ 可见等待比例 ${(result.visibleWaitRatio * 100).toFixed(1)}%`,
  )
  lines.push(`单次上限：${result.maxWait.toFixed(2)}s`)
  lines.push(
    result.keptRatio === null
      ? 'kept：无补页，无法计算'
      : `kept=1：${Math.round(result.keptRatio * result.pages)}/${result.pages}` +
        `（${(result.keptRatio * 100).toFixed(0)}%）`,
  )
  if (result.openMs !== null) lines.push(`首屏：${result.openMs} ms（进程第一条探针 → 第一次画出内容）`)
  lines.push(`prefetch.near：${result.prefetchNear} 次；prefetch.cancel：${result.cancels.length} 次` +
    (result.cancels.length > 0 ? `（${[...new Set(result.cancels)].join('/')}）` : ''))
  return lines.join('\n')
}

const argv = process.argv.slice(2)
const fileIndex = argv.indexOf('--file')
const file = fileIndex >= 0 ? argv[fileIndex + 1] : latestProbeLog()
const result = summarise(parseProbeLog(readFileSync(file, 'utf8')))
if (argv.includes('--json')) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
} else {
  process.stdout.write(`${report(result, file)}\n`)
}
