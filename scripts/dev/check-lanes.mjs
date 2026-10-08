#!/usr/bin/env node
/**
 * 选择性拦截：一次改动 → 该在哪几级渠道取得证据 → 缺哪一级就非零退出。
 *
 * 判定口径**只**来自 `scripts/verify/lanes.json`（矩阵）。这里不写第二份规则：
 * 要改判定就改矩阵；矩阵本身坏掉（缺格、重复、枚举越界、理由缺失、入口与
 * package.json 漂移）按工具自身错误退出 2。
 *
 *   node scripts/dev/check-lanes.mjs --changed plugins/mobile-link/lib/link.js
 *   node scripts/dev/check-lanes.mjs --changed-from changed.txt --json
 *
 * 证据"新鲜"的判据是机械的：证据包的 mtime 必须不早于被改文件里最新的那个。
 */

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

import { readEvidence } from '../verify/evidence.mjs'
import { REPO_ROOT, loadMatrix, requiredLanes, validateLaneEntries, validateMatrix } from '../verify/matrix.mjs'

const DEFAULT_EVIDENCE_ROOT = join(REPO_ROOT, '.lanes', 'runs')

/** 改动清单：显式给的优先；否则用 git（工作区 + 已暂存 + 未跟踪）。 */
export function collectChangedFiles({ changed = [], from = undefined, repo = REPO_ROOT, git = runGit } = {}) {
  if (changed.length > 0) return changed
  if (from) return readFileSync(from, 'utf8').split('\n').map((line) => line.trim()).filter(Boolean)
  const files = new Set()
  for (const args of [['diff', '--name-only', 'HEAD'], ['ls-files', '--others', '--exclude-standard']]) {
    const result = git(args, repo)
    for (const line of result.split('\n')) if (line.trim()) files.add(line.trim())
  }
  return [...files]
}

/**
 * 校验必跑集合的证据。
 * @returns {{required: string[], satisfied: string[], missing: string[], blocked: object[], reasons: object, evidence: object, stale: object}}
 */
export function evaluateEvidence({ required, reasons, entries, evidenceRoot = DEFAULT_EVIDENCE_ROOT, changedFiles = [] } = {}) {
  const newestChange = newestMtime(changedFiles)
  const satisfied = []
  const missing = []
  const blocked = []
  const evidence = {}
  const stale = {}
  for (const lane of required) {
    const candidates = entries.filter((entry) => entry.verdict?.lane === lane && entry.issues.length === 0)
    const passes = candidates.filter((entry) => entry.verdict.status === 'pass')
    const blocks = candidates.filter((entry) => entry.verdict.status === 'blocked')
    const fresh = passes.filter((entry) => mtimeOf(entry.path) >= newestChange)
    if (fresh.length > 0) {
      satisfied.push(lane)
      evidence[lane] = relative(fresh[fresh.length - 1].path)
      continue
    }
    if (passes.length > 0) stale[lane] = `证据比改动旧（${relative(passes[passes.length - 1].path)}）`
    if (blocks.length > 0) {
      blocked.push({ lane, reason: blocks[blocks.length - 1].verdict.blockedReason, nextStep: blocks[blocks.length - 1].verdict.nextStep })
    }
    missing.push(lane)
  }
  return { required, satisfied, missing, blocked, reasons, evidence, stale }
}

function newestMtime(files) {
  let newest = 0
  for (const file of files) {
    const path = resolve(REPO_ROOT, file)
    if (!existsSync(path)) continue
    newest = Math.max(newest, statSync(path).mtimeMs)
  }
  return newest
}

function mtimeOf(path) {
  try {
    return statSync(path).mtimeMs
  } catch {
    return 0
  }
}

function relative(path) {
  return path.startsWith(`${REPO_ROOT}/`) ? path.slice(REPO_ROOT.length + 1) : path
}

function runGit(args, repo) {
  const result = spawnSync('git', args, { cwd: repo, encoding: 'utf8' })
  return result.status === 0 ? result.stdout : ''
}

function parseArgs(argv) {
  const changed = []
  const require = []
  const flags = {}
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--changed') changed.push(argv[++index])
    else if (token === '--require') require.push(argv[++index])
    else if (token === '--changed-from') flags.from = argv[++index]
    else if (token === '--evidence-root') flags.evidenceRoot = argv[++index]
    else if (token === '--json') flags.json = true
    else if (token === '--help' || token === '-h') flags.help = true
    else throw new Error(`未知参数：${token}`)
  }
  return { changed, require, flags }
}

export function gate({ changed = [], from, require: forced = [], evidenceRoot = DEFAULT_EVIDENCE_ROOT, matrixPath } = {}) {
  const matrix = loadMatrix(matrixPath)
  const pkg = JSON.parse(readFileSync(join(REPO_ROOT, 'package.json'), 'utf8'))
  const issues = [...validateMatrix(matrix), ...validateLaneEntries(matrix, pkg.scripts ?? {})]
  if (issues.length > 0) return { exitCode: 2, toolError: issues }

  const files = collectChangedFiles({ changed, from })
  const decision = requiredLanes(matrix, files)
  const required = [...new Set([...decision.required, ...forced])].sort()
  const entries = readEvidence(evidenceRoot)
  const verdict = evaluateEvidence({ required, reasons: decision.reasons, entries, evidenceRoot, changedFiles: files })
  const missing = verdict.missing
  const ok = missing.length === 0
  return {
    exitCode: ok ? 0 : 1,
    ok,
    changedFiles: files,
    subjects: decision.subjects,
    required,
    ...verdict,
    missing,
  }
}

function format(result) {
  if (result.toolError) return `矩阵/入口自身有问题（退出码 2）：\n  ${result.toolError.join('\n  ')}`
  const lines = [`改动命中：${result.subjects.join('、') || '（没有命中任何被测对象）'}`]
  lines.push(`必跑渠道：${result.required.join('、') || '（无）'}`)
  for (const lane of result.required) {
    const why = result.reasons[lane] ?? '被 --require 强制要求'
    if (result.satisfied.includes(lane)) lines.push(`  ok   ${lane} — ${result.evidence[lane]}（${why}）`)
    else lines.push(`  MISS ${lane} — ${why}${result.stale[lane] ? `；${result.stale[lane]}` : ''}`)
  }
  for (const block of result.blocked) lines.push(`  BLOCKED ${block.lane} — ${block.reason}；下一步：${block.nextStep}`)
  if (!result.ok) lines.push('缺证据：跑 `npm run lane:<id> -- run --scenario <name>` 补齐，或说明为什么这一级不需要跑（改矩阵）。')
  return lines.join('\n')
}

async function main(argv = process.argv.slice(2)) {
  let args
  try {
    args = parseArgs(argv)
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    return 2
  }
  if (args.flags.help) {
    process.stdout.write('用法：check-lanes.mjs [--changed <file>]… [--changed-from <file>] [--require <lane>]… [--json]\n')
    return 0
  }
  let result
  try {
    result = gate({ changed: args.changed, from: args.flags.from, require: args.require, evidenceRoot: args.flags.evidenceRoot ?? DEFAULT_EVIDENCE_ROOT })
  } catch (error) {
    process.stderr.write(`工具错误：${error.message}\n`)
    return 2
  }
  process.stdout.write(args.flags.json ? `${JSON.stringify(result, null, 2)}\n` : `${format(result)}\n`)
  return result.exitCode
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().then((code) => process.exit(code), (error) => {
    process.stderr.write(`${error.stack ?? error}\n`)
    process.exit(2)
  })
}
