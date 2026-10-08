#!/usr/bin/env node
/**
 * 开关：「改插件源码」也不用重启 DSH（003 扩展）。
 *
 * 背景：DSH 基础组合里 `hmr` 条目默认 `root: []`——只监听 profile 配置，不监听源码模块。
 * 官方文档里的 `root: ["."]` 对本仓库**不管用**：plugins/ 在仓库里，档案里的
 * `node_modules/dsh-plugin-*` 是指向仓库的符号链接，"."（档案目录）覆盖不到它们（实测）。
 * 把 root 明确指到 <repo>/plugins 之后，保存 lib/index.js 会当场重新挂载该插件（实测）。
 *
 * 本脚本只改本机档案的 `cordis.patch.yml`（用户层），不碰仓库被跟踪的文件、不改插件代码：
 *
 *   node scripts/dev/plugin-hmr.mjs on       # 打开（写两个档案）
 *   node scripts/dev/plugin-hmr.mjs off      # 关闭（删掉本脚本写的块）
 *   node scripts/dev/plugin-hmr.mjs status   # 看当前状态
 *
 * 选项：--profiles web,desktop（默认两个）　--root <dir>（默认 <repo>/plugins）　--dry-run
 *
 * 注意两点：
 *   1. 配置在**启动时**读入，所以打开/关闭之后要重启一次 DSH 才生效（此后改源码就不用重启了）。
 *   2. 打开期间保存源码会让宿主当场重载插件——mobile-link 重载会重连一次手机链路。
 */

import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const REPO = fileURLToPath(new URL('../..', import.meta.url))

/** 本脚本写的块带的注释，用于人工辨认；判定归属只看 root 内容，不看这行（DSH 会重写档案）。 */
export const MARKER = '# plugin-hmr: 宿主监听仓库插件源码（scripts/dev/plugin-hmr.mjs 管理，off 即撤销）'

export const DEFAULT_PROFILES = ['web', 'desktop']

export function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

export function profilePatchPath(profile, home = dshHome()) {
  return join(home, 'profiles', profile, 'cordis.patch.yml')
}

/** 本脚本追加的块。 */
export function hmrBlock(rootDir) {
  return `${MARKER}\n- id: hmr\n  config:\n    root: ["${rootDir}"]\n`
}

/** 顶层 `- id: hmr` 块的行区间（半开）。 */
export function findHmrBlock(text) {
  const lines = text.split('\n')
  const start = lines.findIndex((line) => /^-\s*id:\s*hmr\s*$/.test(line))
  if (start < 0) return undefined
  let end = start + 1
  while (end < lines.length && !/^-\s/.test(lines[end])) end += 1
  return { start, end, lines }
}

/** 块里 `root:` 列出的目录（支持 `root: [...]` 与 YAML 列表两种写法）。 */
export function blockRoots(lines) {
  const roots = []
  const unquote = (value) => value.trim().replace(/^["']|["']$/g, '')
  for (let index = 0; index < lines.length; index += 1) {
    const inline = /^\s+root:\s*\[(.*)\]\s*$/.exec(lines[index])
    if (inline !== null) {
      for (const item of inline[1].split(',')) {
        const value = unquote(item)
        if (value.length > 0) roots.push(value)
      }
      continue
    }
    if (/^\s+root:\s*$/.test(lines[index])) {
      for (let next = index + 1; next < lines.length; next += 1) {
        const item = /^\s+-\s*(.+?)\s*$/.exec(lines[next])
        if (item === null) break
        roots.push(unquote(item[1]))
      }
    }
  }
  return roots
}

/**
 * 打开：没有 hmr 条目就追加一块；已有且 root 含目标目录则不动；已有但指向别处则报冲突
 * （绝不覆盖别人手写的条目）。
 */
export function applyOn(text, rootDir) {
  const block = findHmrBlock(text)
  if (block !== undefined) {
    const roots = blockRoots(block.lines.slice(block.start, block.end))
    if (roots.includes(rootDir)) return { text, changed: false, roots }
    return { text, changed: false, conflict: true, roots }
  }
  const body = text.endsWith('\n') || text.length === 0 ? text : `${text}\n`
  const separator = body.endsWith('\n\n') || body.length === 0 ? '' : '\n'
  return { text: `${body}${separator}${hmrBlock(rootDir)}`, changed: true, roots: [rootDir] }
}

/** 关闭：只删本脚本写的块（root 含目标目录的那一块），其他内容一字不动。 */
export function applyOff(text, rootDir) {
  const block = findHmrBlock(text)
  if (block === undefined) return { text, changed: false }
  const roots = blockRoots(block.lines.slice(block.start, block.end))
  if (!roots.includes(rootDir)) return { text, changed: false, roots, foreign: true }

  const lines = [...block.lines]
  let start = block.start
  if (start > 0 && lines[start - 1].startsWith('# plugin-hmr:')) start -= 1
  // 只删标记与块本身：块前面那个空行同时是原文的收尾换行，删掉会让文件末尾少一个 \n。
  lines.splice(start, block.end - start)
  return { text: lines.join('\n'), changed: true }
}

/** @returns {'on' | 'off' | 'other'} */
export function statusOf(text, rootDir) {
  const block = findHmrBlock(text)
  if (block === undefined) return 'off'
  return blockRoots(block.lines.slice(block.start, block.end)).includes(rootDir) ? 'on' : 'other'
}

function parseArgs(argv) {
  const options = { action: argv[0], profiles: DEFAULT_PROFILES, root: join(REPO, 'plugins'), dryRun: false }
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--dry-run') options.dryRun = true
    else if (arg === '--profiles') options.profiles = String(argv[++index] ?? '').split(',').filter(Boolean)
    else if (arg === '--root') options.root = String(argv[++index] ?? '')
    else throw new Error(`未知参数：${arg}`)
  }
  return options
}

function main(argv) {
  const options = parseArgs(argv)
  if (!['on', 'off', 'status'].includes(options.action)) {
    console.error('用法：node scripts/dev/plugin-hmr.mjs <on|off|status> [--profiles web,desktop] [--root <dir>] [--dry-run]')
    return 2
  }
  const home = dshHome()
  let exitCode = 0

  for (const profile of options.profiles) {
    const path = profilePatchPath(profile, home)
    if (!existsSync(path)) {
      console.log(`${profile}: 没有 ${path}（跳过）`)
      continue
    }
    const text = readFileSync(path, 'utf8')
    if (options.action === 'status') {
      const state = statusOf(text, options.root)
      console.log(`${profile}: ${state}${state === 'other' ? `（root 指在别处：${blockRoots(findHmrBlock(text).lines.slice(findHmrBlock(text).start, findHmrBlock(text).end)).join(', ')}）` : ''}`)
      continue
    }
    const result = options.action === 'on' ? applyOn(text, options.root) : applyOff(text, options.root)
    if (result.conflict) {
      console.error(`${profile}: 已有的 hmr 条目 root 指向别处（${result.roots.join(', ')}），不覆盖；请手工改或先清掉它`)
      exitCode = 1
      continue
    }
    if (result.foreign) {
      console.log(`${profile}: hmr 条目指向别处，未改动`)
      continue
    }
    if (!result.changed) {
      console.log(`${profile}: 已经是「${options.action === 'on' ? '开' : '关'}」，无改动`)
      continue
    }
    if (!options.dryRun) {
      if (existsSync(path)) copyFileSync(path, `${path}.bak-plugin-hmr`)
      writeFileSync(path, result.text)
    }
    console.log(`${profile}: 已${options.action === 'on' ? '打开' : '关闭'}${options.dryRun ? '（dry-run，未写入）' : ''}`)
    if (options.action === 'off' && options.dryRun === false) console.log(`  （备份：${path}.bak-plugin-hmr）`)
  }

  if (exitCode === 0 && options.action !== 'status' && options.dryRun === false) {
    console.log('\n配置在启动时读取：现在重启一次 DSH 生效；此后改插件源码不用再重启。')
  }
  return exitCode
}

// 只有被直接当成脚本跑时才执行；被单测 import 时不能有副作用。
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)))
}
