#!/usr/bin/env node
/**
 * 文件级与声明级下钻层：从"模块"再往下走两层。
 *
 *   模块（scan.mjs 的节点）
 *     └─ 文件（本模块的 nodes/edges）
 *          └─ 声明（类型、协议、继承、函数；带行号）
 *
 * 可靠性分档，页面上要能看出来：
 *   - structural：继承与协议实现。语法明确，可信。
 *   - import    ：JS/Python 的相对 import 落到具体文件。可信。
 *   - reference ：Swift 文件之间的类型引用。启发式，会漏也会误。
 *
 * 只读、零依赖。性能上必须先用词法扫出候选类型名再逐个确认，不能拿全仓类型索引
 * 去 regex 每个文件——文件级那样会慢到不能用。
 */

import { extname } from 'node:path'

import {
  walk, rel, countLines, parseSwift, parseJs, parsePy, parseSwiftDeclarations,
  swiftCandidateNames, swiftUsesType, swiftShadowsName, SWIFT_TYPE_STOPLIST,
  resolveJsSpecifier,
} from './parse.mjs'

const MAX_FUNCS_PER_FILE = 40

/** 全仓"类型名 → 唯一声明它的文件"。多文件同名的一律放弃，避免把泛用名当依赖。 */
function buildTypeOwnerIndex(groups) {
  const owners = new Map()
  for (const group of groups) {
    if (group.layer !== 'ios-app' && group.layer !== 'ios-kit') continue
    for (const abs of walk(group.abs)) {
      if (extname(abs) !== '.swift') continue
      for (const name of parseSwift(abs).declared) {
        if (SWIFT_TYPE_STOPLIST.has(name) || name.length < 4) continue
        if (!owners.has(name)) owners.set(name, new Set())
        owners.get(name).add(rel(abs))
      }
    }
  }
  const unique = new Map()
  for (const [name, fileIds] of owners) if (fileIds.size === 1) unique.set(name, [...fileIds][0])
  return unique
}

function fileNode(abs, declarations) {
  const fileId = rel(abs)
  const declaration = declarations[fileId]
  return {
    id: fileId,
    label: fileId.split('/').pop(),
    dir: fileId.split('/').slice(0, -1).join('/'),
    lines: countLines(abs),
    typeCount: declaration ? declaration.types.length : 0,
    funcCount: declaration ? declaration.funcCount : 0,
  }
}

/** Swift 文件之间的类型引用（启发式）：先取候选名，再确认语法位置。 */
function swiftFileEdges(abs, typeOwners, add) {
  const fileId = rel(abs)
  const { code } = parseSwift(abs)
  for (const name of swiftCandidateNames(code)) {
    const owner = typeOwners.get(name)
    if (!owner || owner === fileId) continue
    if (swiftShadowsName(code, name) || !swiftUsesType(code, name)) continue
    add(fileId, owner, 'reference', name)
  }
}

/** 继承与协议实现：同一模块内解析到具体文件，模块外只记名字（由页面显示为"外部"）。 */
function structuralEdges(fileId, declarations, typeOwners, add) {
  for (const type of declarations[fileId]?.types ?? []) {
    for (const parent of type.inherits) {
      const owner = typeOwners.get(parent)
      if (owner && owner !== fileId) add(fileId, owner, 'structural', `${type.name} : ${parent}`)
    }
  }
}

/** JS 的相对 import 落到具体文件（权威）。 */
function jsFileEdges(abs, add) {
  const fileId = rel(abs)
  for (const specifier of parseJs(abs).specifiers) {
    const resolved = resolveJsSpecifier(specifier, abs)
    if (resolved) add(fileId, rel(resolved), 'import', specifier)
  }
}

/** Python：同一模块内按模块名映射到文件。 */
function pyFileEdges(abs, moduleToFile, add) {
  const fileId = rel(abs)
  for (const name of parsePy(abs).modules) {
    const owner = moduleToFile.get(name)
    if (owner && owner !== fileId) add(fileId, owner, 'import', `import ${name}`)
  }
}

/** 每个 Swift 文件的声明清单；先扫一遍，文件节点的计数要用。 */
function collectDeclarations(groups, declarations) {
  for (const group of groups) {
    for (const abs of walk(group.abs)) {
      if (extname(abs) !== '.swift') continue
      const { types, funcs } = parseSwiftDeclarations(abs)
      declarations[rel(abs)] = { types, funcs: funcs.slice(0, MAX_FUNCS_PER_FILE), funcCount: funcs.length }
    }
  }
}

/** 全部文件的节点（带所属模块），供各模块子图按需挑选。 */
function collectAllNodes(groups, declarations) {
  const all = new Map()
  for (const group of groups) {
    for (const abs of walk(group.abs)) {
      const node = fileNode(abs, declarations)
      node.group = group.id
      all.set(node.id, node)
    }
  }
  return all
}

/** 一个模块内部的文件级边：Swift 类型引用 + 继承，JS 相对 import，Python 模块 import。 */
function buildGroupEdges(group, typeOwners, declarations) {
  const files = walk(group.abs)
  const edgeMap = new Map()
  const add = (from, to, kind, detail) => {
    if (!from || !to || from === to) return
    const key = `${from}->${to}`
    const edge = edgeMap.get(key) ?? { from, to, kind, samples: new Set() }
    if (kind === 'structural') edge.kind = kind
    else if (kind === 'import' && edge.kind === 'reference') edge.kind = kind
    if (detail) edge.samples.add(detail)
    edgeMap.set(key, edge)
  }

  for (const abs of files) {
    if (extname(abs) === '.swift') {
      swiftFileEdges(abs, typeOwners, add)
      structuralEdges(rel(abs), declarations, typeOwners, add)
    } else if (['.js', '.mjs', '.cjs'].includes(extname(abs))) {
      jsFileEdges(abs, add)
    }
  }
  const pyFiles = files.filter((abs) => extname(abs) === '.py')
  const moduleToFile = new Map()
  for (const abs of pyFiles) {
    const name = abs.endsWith('__init__.py') ? abs.split('/').slice(-2)[0] : abs.split('/').pop().replace(/\.py$/, '')
    moduleToFile.set(name, rel(abs))
  }
  for (const abs of pyFiles) pyFileEdges(abs, moduleToFile, add)

  return [...edgeMap.values()]
    .map((edge) => ({ ...edge, samples: [...edge.samples].slice(0, 3) }))
    .sort((a, b) => (a.from === b.from ? a.to.localeCompare(b.to) : a.from.localeCompare(b.to)))
}

/** 本模块有连线的文件 + 被它们引用的模块外文件（后者标 external）。 */
function assembleGroupNodes(groupId, edges, allNodes) {
  const connected = new Set()
  for (const edge of edges) {
    connected.add(edge.from)
    connected.add(edge.to)
  }
  const nodes = [...allNodes.values()]
    .filter((node) => node.group === groupId && connected.has(node.id))
    .sort((a, b) => b.lines - a.lines)
  for (const edge of edges) {
    if (!allNodes.has(edge.to) || nodes.some((node) => node.id === edge.to)) continue
    nodes.push({ ...allNodes.get(edge.to), external: allNodes.get(edge.to).group !== groupId })
  }
  const isolatedCount = [...allNodes.values()].filter((node) => node.group === groupId && !connected.has(node.id)).length
  return { nodes, edges, isolatedCount }
}

/**
 * 构建文件级图层。
 * 每个模块的子图 = 本模块内有连线的文件 + 被它们引用的模块外文件（标 external），
 * 这样一眼能看出"这个模块的代码往外伸到了哪里"。
 * @returns {{ byGroup: Record<string, {nodes: any[], edges: any[], isolatedCount: number}>, declarations: Record<string, any> }}
 */
export function buildFileLayer(groups) {
  const typeOwners = buildTypeOwnerIndex(groups)
  const declarations = {}
  collectDeclarations(groups, declarations)
  const allNodes = collectAllNodes(groups, declarations)

  const byGroup = {}
  for (const group of groups) {
    byGroup[group.id] = assembleGroupNodes(group.id, buildGroupEdges(group, typeOwners, declarations), allNodes)
  }
  return { byGroup, declarations }
}
