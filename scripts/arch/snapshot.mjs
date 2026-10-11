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
 * 只读扫描、零新增依赖；工具自身出错才返回非零。
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { buildGraph, ROOT } from './scan.mjs'
import { renderPage } from './render.mjs'

const ARCH_DIR = join(ROOT, 'docs/arch')
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

function main() {
  const graph = buildGraph()
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
  const versionDir = join(ARCH_DIR, version)
  mkdirSync(versionDir, { recursive: true })

  // 归档副本：路径多一层，版本下拉要回到上级目录
  writeFileSync(join(versionDir, 'index.html'), renderPage({
    graph, versions: allVersions, current: version, diff, linkPrefix: '../',
  }))
  writeFileSync(join(versionDir, 'graph.json'), `${JSON.stringify(graph, null, 2)}\n`)
  if (diff) writeFileSync(join(versionDir, 'diff.json'), `${JSON.stringify(diff, null, 2)}\n`)

  // 稳定入口：始终是最新一版，浏览器停在这里刷新即可
  writeFileSync(join(ARCH_DIR, 'index.html'), renderPage({
    graph, versions: allVersions, current: version, diff, linkPrefix: './',
  }))
  writeFileSync(join(ARCH_DIR, 'latest.json'), `${JSON.stringify({ version, generatedAt: graph.meta.generatedAt, commit: graph.meta.commit }, null, 2)}\n`)

  const added = diff ? diff.addedEdges.length : 0
  const removed = diff ? diff.removedEdges.length : 0
  console.log(`已生成 ${version}：${graph.meta.groupCount} 模块 / ${graph.meta.edgeCount} 边 / ${graph.meta.cycleCount} 处循环`)
  if (diff) console.log(`与 ${diff.previous} 相比：新增边 ${added}，消失边 ${removed}，模块增删 ${diff.addedNodes.length}/${diff.removedNodes.length}`)
  else console.log('这是第一版，没有可对比的上一版')
  console.log(`打开：${join(ARCH_DIR, 'index.html')}`)
  if (graph.meta.droppedEdges?.length) {
    console.log(`已丢弃结构性不可能的边：${graph.meta.droppedEdges.join('、')}`)
  }
}

main()
