#!/usr/bin/env node
/**
 * 架构快照入口：扫描 → 渲染 → 落到 `docs/arch/<版本>/`。
 *
 *   npm run arch                        # 生成下一版（v001、v002…）
 *   npm run arch -- --version v003      # 指定版本目录（已存在则覆盖）
 *   npm run arch -- --note "重构会话列表"  # 给这一版记一句话
 *   npm run arch -- --json              # 只打印汇总，不写文件
 *
 * 目录约定：
 *   docs/arch/index.html        永远是最新一版（浏览器停在这里，刷新即最新）
 *   docs/arch/vNNN/index.html   该版本的归档副本，不再变化
 *   docs/arch/vNNN/graph.json   该版本的原始扫描结果
 *   docs/arch/vNNN/diff.json    与上一版的差异
 *
 * 深查询（真实调用关系）来自 `npm run arch:deep` 写下的 docs/arch/deep.json；
 * 本命令只读缓存，所以快路径不依赖 sourcekit-lsp。
 *
 * 只读扫描、零新增依赖；工具自身出错才返回非零。
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { buildGraph, ROOT } from './scan.mjs'
import { loadFlows } from './flows.mjs'
import { loadCache, markStale } from './deep.mjs'
import { renderPage } from './render.mjs'

const ARCH_DIR = join(ROOT, 'docs/arch')
const CLIENT_SRC = join(ROOT, 'scripts/arch/client.js')
const argv = process.argv.slice(2)
const has = (name) => argv.includes(`--${name}`)
const valueOf = (name) => {
  const index = argv.indexOf(`--${name}`)
  return index === -1 ? null : argv[index + 1] ?? null
}

function existingVersions() {
  if (!existsSync(ARCH_DIR)) return []
  return readdirSync(ARCH_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^v\d{3}$/.test(entry.name))
    .map((entry) => entry.name)
    .sort()
}

function nextVersion(versions) {
  if (!versions.length) return 'v001'
  const latest = Number(versions[versions.length - 1].slice(1))
  return `v${String(latest + 1).padStart(3, '0')}`
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return null
  }
}

/** 与上一版比依赖边和模块的增删。 */
function computeDiff(previous, graph, previousVersion) {
  if (!previous) return null
  const key = (edge) => `${edge.from}->${edge.to}`
  const before = new Map(previous.edges.map((edge) => [key(edge), edge]))
  const after = new Map(graph.edges.map((edge) => [key(edge), edge]))
  const previousNodes = new Set(previous.nodes.map((node) => node.id))
  const currentNodes = new Set(graph.nodes.map((node) => node.id))
  const metricKeys = ['fileCount', 'lineCount', 'groupCount', 'edgeCount', 'cycleCount']
  const metrics = {}
  for (const name of metricKeys) metrics[name] = (graph.meta[name] ?? 0) - (previous.meta?.[name] ?? 0)
  return {
    previous: previousVersion,
    addedEdges: [...after.values()].filter((edge) => !before.has(key(edge))),
    removedEdges: [...before.values()].filter((edge) => !after.has(key(edge))),
    addedNodes: [...currentNodes].filter((id) => !previousNodes.has(id)),
    removedNodes: [...previousNodes].filter((id) => !currentNodes.has(id)),
    changedEdges: [...after.values()]
      .filter((edge) => before.has(key(edge)) && before.get(key(edge)).kind !== edge.kind),
    metrics,
  }
}

/** 落盘：归档副本 + 稳定入口 + 原始数据。 */
function writeVersion({ graph, version, allVersions, diff }) {
  const versionDir = join(ARCH_DIR, version)
  mkdirSync(versionDir, { recursive: true })
  // graph.json 是逐版对比用的，不放深查询明细（明细在 docs/arch/deep.json）
  const { deep, ...archived } = graph

  // 归档副本：路径多一层，版本下拉要回到上级目录；交互脚本随版本一起冻结
  writeFileSync(join(versionDir, 'client.js'), readFileSync(CLIENT_SRC, 'utf8'))
  writeFileSync(join(versionDir, 'index.html'), renderPage({
    graph, versions: allVersions, current: version, diff, linkPrefix: '../', assetPrefix: './',
  }))
  writeFileSync(join(versionDir, 'graph.json'), `${JSON.stringify(archived, null, 2)}\n`)
  if (diff) writeFileSync(join(versionDir, 'diff.json'), `${JSON.stringify(diff, null, 2)}\n`)

  // 稳定入口：始终是最新一版，浏览器停在这里刷新即可；脚本指到该版本目录，避免重复拷贝
  writeFileSync(join(ARCH_DIR, 'index.html'), renderPage({
    graph, versions: allVersions, current: version, diff, linkPrefix: './', assetPrefix: `./${version}/`,
  }))
  writeFileSync(join(ARCH_DIR, 'latest.json'),
    `${JSON.stringify({ version, generatedAt: graph.meta.generatedAt, commit: graph.meta.commit }, null, 2)}\n`)
}

/** 终端汇总：只讲变了什么、哪里要人看。 */
function report(graph, version, diff) {
  console.log(`已生成 ${version}：${graph.meta.groupCount} 模块 / ${graph.meta.edgeCount} 边 / ${graph.meta.cycleCount} 处循环`)
  if (diff) {
    console.log(`与 ${diff.previous} 相比：新增边 ${diff.addedEdges.length}，消失边 ${diff.removedEdges.length}，模块增删 ${diff.addedNodes.length}/${diff.removedNodes.length}`)
  } else {
    console.log('这是第一版，没有可对比的上一版')
  }
  if (graph.flows.length) {
    const broken = graph.meta.flowBrokenCount
    console.log(`流程 ${graph.flows.length} 条${broken ? `，其中 ${broken} 处符号校验失败（页面会标红）` : '，符号校验全部通过'}`)
  }
  if (graph.meta.deepCallCount) {
    console.log(`深查询缓存：${graph.meta.deepCallCount} 条真实调用${graph.meta.deepStaleCount ? `，其中 ${graph.meta.deepStaleCount} 条目标符号已改名（页面会标出）` : ''}`)
  }
  if (graph.meta.droppedEdges?.length) {
    console.log(`已丢弃结构性不可能的边：${graph.meta.droppedEdges.join('、')}`)
  }
  console.log(`打开：${join(ARCH_DIR, 'index.html')}`)
}

/**
 * 附上深查询结果。缓存里的目标符号可能已被改名，这里用当前声明清单核对，
 * 核对不上的边标 stale，页面会提示而不是装作有效。
 */
function attachDeep(graph) {
  const cache = loadCache()
  const ids = Object.keys(cache.files || {})
  if (!ids.length) return
  const deep = { generatedAt: cache.generatedAt, files: {} }
  let calls = 0
  let stale = 0
  let system = 0
  for (const id of ids) {
    const entry = markStale(cache.files[id], graph.declarations)
    // 页面只放跨文件调用：同文件内的调用对架构判断没用，放进页面只是把 HTML 撑大
    const crossFile = entry.calls.filter((call) => call.toFile !== id)
    deep.files[id] = { calls: crossFile }
    calls += crossFile.length
    stale += crossFile.filter((call) => call.stale).length
    system += entry.systemCalls || 0
  }
  graph.deep = deep
  graph.meta.deepGeneratedAt = cache.generatedAt
  graph.meta.deepCallCount = calls
  graph.meta.deepStaleCount = stale
  graph.meta.deepSystemCallCount = system
}

function main() {
  const graph = buildGraph()
  graph.flows = loadFlows(graph.declarations)
  graph.meta.flowCount = graph.flows.length
  graph.meta.flowBrokenCount = graph.flows.reduce((sum, flow) => sum + flow.steps.filter((step) => !step.ok).length, 0)
  attachDeep(graph)
  const versions = existingVersions()

  if (has('json')) {
    process.stdout.write(`${JSON.stringify({ meta: graph.meta, cycles: graph.cycles }, null, 2)}\n`)
    return
  }

  const version = valueOf('version') ?? nextVersion(versions)
  if (!/^v\d{3}$/.test(version)) {
    console.error(`版本目录名要形如 v001，收到的是 ${version}`)
    process.exit(2)
  }

  const previousVersion = versions.filter((name) => name < version).pop() ?? null
  const previous = previousVersion ? readJson(join(ARCH_DIR, previousVersion, 'graph.json')) : null
  const diff = computeDiff(previous, graph, previousVersion)
  if (valueOf('note')) graph.meta.note = valueOf('note')

  const allVersions = [...new Set([...versions, version])].sort()
  writeVersion({ graph, version, allVersions, diff })
  report(graph, version, diff)

}
main()
