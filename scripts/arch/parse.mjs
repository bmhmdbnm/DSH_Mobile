#!/usr/bin/env node
/**
 * 架构快照的解析层：文件遍历 + 各语言的 import/类型提取。
 *
 * 这一层只做"从源码里读出结构"，不关心分组与图；分组的逻辑在 scan.mjs。
 * 拆出来的原因：解析函数多，混在 scan.mjs 里会被仓库自己的 500 行/50 行门禁点名。
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { dirname, extname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

const SKIP_DIRS = new Set(['.git', 'node_modules', '__pycache__', '.build', 'build', 'dist', '.venv'])
const CODE_EXT = new Set(['.swift', '.js', '.mjs', '.cjs', '.py'])

export const rel = (abs) => relative(ROOT, abs)

/** 递归列出目录下的代码文件（跳过构建产物与依赖目录）。 */
export function walk(absDir, out = []) {
  if (!existsSync(absDir)) return out
  for (const entry of readdirSync(absDir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue
    const abs = join(absDir, entry.name)
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue
      walk(abs, out)
    } else if (CODE_EXT.has(extname(entry.name))) {
      out.push(abs)
    }
  }
  return out
}

export function dirsIn(absDir) {
  if (!existsSync(absDir)) return []
  return readdirSync(absDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !SKIP_DIRS.has(entry.name) && !entry.name.startsWith('.'))
    .map((entry) => entry.name)
    .sort()
}

export function countLines(abs) {
  try {
    return readFileSync(abs, 'utf8').split('\n').length
  } catch {
    return 0
  }
}

/**
 * 去掉 Swift 注释与字符串字面量。
 * 不做这一步，类型引用统计会被注释里提到的类名和文案污染——上一版就是这样冒出
 * "DSHKit 依赖 App" 这种反向边的。
 */
export function stripSwiftNoise(text) {
  let out = ''
  let i = 0
  while (i < text.length) {
    const two = text.slice(i, i + 2)
    if (two === '//') {
      while (i < text.length && text[i] !== '\n') i += 1
    } else if (two === '/*') {
      const end = text.indexOf('*/', i + 2)
      i = end === -1 ? text.length : end + 2
    } else if (text[i] === '"') {
      if (text.slice(i, i + 3) === '"""') {
        const end = text.indexOf('"""', i + 3)
        i = end === -1 ? text.length : end + 3
      } else {
        i += 1
        while (i < text.length && text[i] !== '"') {
          if (text[i] === '\\') i += 1
          i += 1
        }
        i += 1
      }
    } else {
      out += text[i]
      i += 1
    }
  }
  return out
}

/** Swift：取 import、真正声明的类型名、被 extension 的类型名。 */
export function parseSwift(abs) {
  const text = readFileSync(abs, 'utf8')
  const imports = [...text.matchAll(/^\s*(?:@testable\s+)?import\s+([A-Za-z_][\w]*)/gm)].map((m) => m[1])
  const declared = new Set()
  for (const match of text.matchAll(/\b(?:struct|class|enum|actor|protocol|typealias)\s+([A-Z][A-Za-z0-9_]{2,})/g)) {
    declared.add(match[1])
  }
  const extended = new Set()
  for (const match of text.matchAll(/\bextension\s+([A-Z][A-Za-z0-9_]{2,})/g)) extended.add(match[1])
  return {
    imports: [...new Set(imports)],
    declared,
    extended,
    types: new Set([...declared, ...extended]),
    code: stripSwiftNoise(text),
  }
}

/** JS：取 import / require 的裸说明符。 */
export function parseJs(abs) {
  const text = readFileSync(abs, 'utf8')
  const specifiers = []
  const patterns = [
    /(?:^|\n)\s*import\s[^'"\n]*?from\s*['"]([^'"]+)['"]/g,
    /(?:^|\n)\s*import\s*['"]([^'"]+)['"]/g,
    /require\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    /(?:^|\n)\s*export\s[^'"\n]*?from\s*['"]([^'"]+)['"]/g,
  ]
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) specifiers.push(match[1])
  }
  return { specifiers: [...new Set(specifiers)] }
}

/** Python：取 import 的模块名（顶层名与末段名都收，兼容 `from relay.store import x`）。 */
export function parsePy(abs) {
  const text = readFileSync(abs, 'utf8')
  const modules = new Set()
  for (const match of text.matchAll(/^\s*from\s+([A-Za-z_][\w.]*)\s+import/gm)) {
    const parts = match[1].split('.')
    modules.add(parts[0])
    modules.add(parts[parts.length - 1])
  }
  for (const match of text.matchAll(/^\s*import\s+([A-Za-z_][\w.]*)/gm)) {
    for (const part of match[1].split(',')) modules.add(part.trim().split('.')[0])
  }
  return { modules: [...modules] }
}

/** 类型用法要落在"像类型"的语法位置，才计入跨组引用。 */
export function swiftUsesType(code, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const patterns = [
    new RegExp(`[:<(,\\[]\\s*${escaped}\\b`), // 类型标注、泛型、数组、继承列表
    new RegExp(`->\\s*${escaped}\\b`), // 返回类型
    new RegExp(`\\b${escaped}\\s*\\(`), // 构造调用
    new RegExp(`\\b${escaped}\\s*\\.`), // 静态访问
  ]
  return patterns.some((pattern) => pattern.test(code))
}

/** 泛型参数会遮蔽同名类型（RelayKit 的 `func call<Envelope: Decodable>`），这种文件跳过。 */
export function swiftShadowsName(code, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`<\\s*${escaped}\\b`).test(code) || new RegExp(`[,<]\\s*${escaped}\\s*:`).test(code)
}

/** 常见词不进类型引用统计，避免把 View/Model 这类泛用名当依赖。 */
export const SWIFT_TYPE_STOPLIST = new Set([
  'View', 'Body', 'Model', 'Error', 'Data', 'Self', 'Task', 'Main', 'Actor', 'Object', 'Value', 'State', 'Color',
])

/** SPM target 依赖：优先 `swift package describe`，失败则整体放弃（并在 meta 里标注）。 */
export function swiftPackageTargets() {
  const kitDir = join(ROOT, 'ios/DSHMobile/DSHKit')
  if (!existsSync(join(kitDir, 'Package.swift'))) return { source: 'absent', targets: [] }
  try {
    const raw = execFileSync('swift', ['package', 'describe', '--type', 'json'], {
      cwd: kitDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 32 * 1024 * 1024,
    })
    const targets = (JSON.parse(raw).targets ?? [])
      .filter((target) => target.type === 'library' || target.module_type === 'SwiftTarget')
      .map((target) => ({
        name: target.name,
        path: target.path,
        deps: target.target_dependencies ?? [],
        isTest: /Tests?$/.test(target.name),
      }))
    return { source: 'swift-package-describe', targets }
  } catch {
    return { source: 'unavailable', targets: [] }
  }
}

export function resolveJsSpecifier(specifier, fromAbs) {
  if (!specifier.startsWith('.')) return null
  const base = join(dirname(fromAbs), specifier)
  const candidates = [base, `${base}.js`, `${base}.mjs`, `${base}.cjs`, join(base, 'index.js'), join(base, 'index.mjs')]
  for (const candidate of candidates) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate
  }
  return null
}

/** 一个文件属于哪个分组：取路径前缀最长（最具体）的那个。 */
export function groupOfFile(abs, groups) {
  const relPath = rel(abs)
  let best = null
  for (const group of groups) {
    if (relPath === group.dir || relPath.startsWith(`${group.dir}/`)) {
      if (!best || group.dir.length > best.dir.length) best = group
    }
  }
  return best
}

/** Tarjan 强连通分量：只回长度 > 1 的分量，也就是真正的循环依赖。 */
export function tarjan(nodes, edges) {
  const adjacency = new Map(nodes.map((node) => [node.id, []]))
  for (const edge of edges) if (adjacency.has(edge.from)) adjacency.get(edge.from).push(edge.to)
  let index = 0
  const stack = []
  const onStack = new Set()
  const indices = new Map()
  const low = new Map()
  const components = []
  const strongConnect = (v) => {
    indices.set(v, index)
    low.set(v, index)
    index += 1
    stack.push(v)
    onStack.add(v)
    for (const w of adjacency.get(v) ?? []) {
      if (!indices.has(w)) {
        strongConnect(w)
        low.set(v, Math.min(low.get(v), low.get(w)))
      } else if (onStack.has(w)) {
        low.set(v, Math.min(low.get(v), indices.get(w)))
      }
    }
    if (low.get(v) !== indices.get(v)) return
    const component = []
    let w
    do {
      w = stack.pop()
      onStack.delete(w)
      component.push(w)
    } while (w !== v)
    if (component.length > 1) components.push(component.sort())
  }
  for (const node of nodes) if (!indices.has(node.id)) strongConnect(node.id)
  return components
}

function git(args) {
  try {
    return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return ''
  }
}
export const gitCommit = () => git(['rev-parse', '--short', 'HEAD']) || 'unknown'
export const gitBranch = () => git(['rev-parse', '--abbrev-ref', 'HEAD']) || 'unknown'
export const gitDirty = () => git(['status', '--porcelain']).split('\n').filter(Boolean).length
