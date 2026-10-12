#!/usr/bin/env node
/**
 * App 构建号（`CFBundleVersion`）与它对外显示的时间，口径统一为**北京时间**。
 *
 * 为什么单独成文件并从发布脚本里调出来：这三条规则都踩过坑，而它们都是纯函数，
 * 放在 shell 里只能靠"发一次试一次"来验证。
 *
 *   1. **形状必须是 `yyyyMMdd.HHmm`**。`CFBundleVersion` 规定是 1–3 段、每段 ≤ 4294967295
 *      的整数。早先那个 12 位时间戳（`202609161637`）越界，iOS 拉完 manifest、探了包，
 *      然后**静默不装**——只有删掉 App 才装得上。落在范围内的号才能正常覆盖安装。
 *   2. **时区统一到北京时间**。以前构建号用 UTC，而安装页那行「构建于」用本机时间，
 *      同一个发布在两处差 8 小时、跨零点时还差一天；CHANGELOG、提交信息又都是本地日期。
 *      现在四处同源：构建号、安装页、`version.json`、文档。
 *   3. **严格递增**。iOS 只肯装"比已装的更新"的构建：同一分钟内发两次、或者用 `--no-build`
 *      复用一份旧归档，号不增，用户点了安装没反应，看上去像"非要先删掉旧 App"。
 *      `planBuildNumber()` 会拿线上 `version.json` 里的号做下界，不够就往前挪到比它大。
 */

import { readFileSync } from 'node:fs'

/** 与 iOS 比较 `CFBundleVersion` 的方式一致：逐段按整数比。 */
export function isNewer(candidate, current) {
  const lhs = parseSegments(candidate)
  const rhs = parseSegments(current)
  if (lhs.length === 0) return false
  for (let index = 0; index < Math.max(lhs.length, rhs.length); index += 1) {
    const left = lhs[index] ?? 0
    const right = rhs[index] ?? 0
    if (left !== right) return left > right
  }
  return false
}

function parseSegments(value) {
  if (typeof value !== 'string' || value.trim() === '') return []
  return value.split('.').map((part) => {
    const n = Number.parseInt(part, 10)
    return Number.isFinite(n) && n >= 0 ? n : 0
  })
}

const pad = (value, width = 2) => String(value).padStart(width, '0')

/**
 * 北京时间的 `yyyyMMdd.HHmm`。
 *
 * 用「UTC 加 8 小时再取 UTC 字段」而不是 `Intl`：发布脚本跑在什么时区、有没有完整
 * ICU 数据都不该影响构建号，加 8 小时是恒定的（中国自 1991 年起不再有夏令时）。
 */
export function beijingStamp(now = new Date()) {
  const shifted = new Date(now.getTime() + 8 * 60 * 60 * 1000)
  return `${shifted.getUTCFullYear()}${pad(shifted.getUTCMonth() + 1)}${pad(shifted.getUTCDate())}`
    + `.${pad(shifted.getUTCHours())}${pad(shifted.getUTCMinutes())}`
}

/** 把 `yyyyMMdd.HHmm` 读回一个 UTC 时刻（只为做加减与比较，不代表真实时区）。 */
function stampToDate(stamp) {
  const match = /^(\d{8})\.(\d{4})$/.exec(String(stamp ?? '').trim())
  if (!match) return null
  const [, day, clock] = match
  const date = new Date(Date.UTC(
    Number(day.slice(0, 4)), Number(day.slice(4, 6)) - 1, Number(day.slice(6, 8)),
    Number(clock.slice(0, 2)), Number(clock.slice(2, 4)),
  ))
  return Number.isNaN(date.getTime()) ? null : date
}

/**
 * 这一次发布该用哪个构建号：北京时间现在，且**必须大于**线上已经发布的那一个。
 *
 * @param {{now?: Date, published?: string}} options `published` 是线上 `version.json` 的
 *   `build`（拿不到就传空串，此时只保证形状与时区正确）。
 */
export function planBuildNumber({ now = new Date(), published = '' } = {}) {
  let stamp = beijingStamp(now)
  const current = stampToDate(stamp)
  const previous = stampToDate(published)
  if (current && previous && current.getTime() <= previous.getTime()) {
    // 比线上旧（同一分钟发两次、或本机时钟落后）：挪到线上号的下一分钟，宁可号"跳一点"，
    // 也不能发一个 iOS 会静默忽略的构建。
    const bumped = new Date(previous.getTime() + 60 * 1000)
    stamp = `${bumped.getUTCFullYear()}${pad(bumped.getUTCMonth() + 1)}${pad(bumped.getUTCDate())}`
      + `.${pad(bumped.getUTCHours())}${pad(bumped.getUTCMinutes())}`
  }
  return stamp
}

function main(argv) {
  const args = { published: '', now: undefined, compare: undefined, readPublished: false }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--published') args.published = argv[++index] ?? ''
    else if (arg === '--now') args.now = new Date(argv[++index] ?? '')
    else if (arg === '--compare') args.compare = [argv[++index] ?? '', argv[++index] ?? '']
    else if (arg === '--read-published') args.readPublished = true
    else if (arg === '--help' || arg === '-h') {
      console.log('用法: ota-version.mjs [--published <线上构建号>] [--now <ISO 时间>]'
        + ' | --compare <候选> <当前> | --read-published（从 stdin 读 version.json，打印它的 build）')
      return 0
    } else {
      console.error(`error: 未知参数 ${arg}`)
      return 2
    }
  }
  if (args.readPublished) {
    // 给发布脚本用：从 stdin 读线上 version.json，只取 `build`。读不到就打印空串——
    // 发布不该因为站点暂时取不到而停下，此时构建号退回"按本机时间打"。
    let raw = ''
    try {
      raw = readFileSync(0, 'utf8')
      process.stdout.write(String(JSON.parse(raw).build ?? ''))
    } catch {
      /* 空输出即"没有线上号" */
    }
    return 0
  }
  if (args.compare) {
    // 退出码给 shell 用：0 = 候选更新（iOS 肯装），1 = 不够新（点了会没反应）。
    return isNewer(args.compare[0], args.compare[1]) ? 0 : 1
  }
  console.log(planBuildNumber({ now: args.now, published: args.published }))
  return 0
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  process.exit(main(process.argv.slice(2)))
}
