#!/usr/bin/env node
/**
 * 架构快照渲染器：把 scan.mjs 的结果渲染成**单文件、离线可开**的 HTML。
 *
 * 设计取舍：
 *   - 不引 Mermaid / d3 / vis-network 等 CDN 依赖，双击就能看，断网也能看。
 *   - 布局在浏览器里算（列式分层），所以切换 scope、隐藏启发式边都不需要重新生成。
 *   - 启发式边默认隐藏、红色虚线表示环；口径写在页面底部，避免被当成权威结论。
 */

const LAYER_LABEL = {
  'ios-app': 'iOS App',
  'ios-kit': 'iOS Kit（SPM）',
  js: 'JS / Node',
  py: 'Python',
}

const esc = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]))

const shortName = (id) => id.split('/').slice(-1)[0]

function badge(text, kind = '') {
  return `<span class="badge ${kind}">${esc(text)}</span>`
}

function diffSection(diff) {
  if (!diff) {
    return `<p class="muted">这是第一版快照，没有可对比的上一版。下一版起这里会列出新增与消失的依赖边。</p>`
  }
  const rows = []
  for (const edge of diff.addedEdges) rows.push(`<li class="add">＋ ${esc(edge.from)} → ${esc(edge.to)} <em>${esc(edge.kind)}</em></li>`)
  for (const edge of diff.removedEdges) rows.push(`<li class="del">－ ${esc(edge.from)} → ${esc(edge.to)}</li>`)
  const nodeRows = []
  for (const id of diff.addedNodes) nodeRows.push(`<li class="add">＋ 新模块 ${esc(id)}</li>`)
  for (const id of diff.removedNodes) nodeRows.push(`<li class="del">－ 模块消失 ${esc(id)}</li>`)
  if (!rows.length && !nodeRows.length) {
    return `<p class="muted">与 ${esc(diff.previous)} 相比：依赖结构没有变化（节点、边均一致）。</p>`
  }
  return `<ul class="diff">${nodeRows.join('')}${rows.join('')}</ul>`
}

function cycleSection(graph) {
  if (!graph.cycles.length) return `<p class="muted">没有检测到循环依赖。</p>`
  return graph.cycles
    .map((cycle) => `<div class="cycle"><b>${cycle.size} 个模块互相依赖</b><div class="chain">${cycle.members.map((id) => `<code>${esc(id)}</code>`).join('<span>→</span>')}</div></div>`)
    .join('')
}

function externalSection(graph) {
  const byLayer = new Map()
  for (const item of graph.externals) {
    if (!byLayer.has(item.layer)) byLayer.set(item.layer, [])
    byLayer.get(item.layer).push(item)
  }
  return [...byLayer.entries()]
    .map(([layer, items]) => {
      const top = items.slice(0, 10).map((item) => `<code>${esc(item.name)}</code><span class="count">${item.count}</span>`).join('')
      return `<div class="ext-group"><h4>${esc(LAYER_LABEL[layer] ?? layer)}</h4><div class="ext-list">${top}</div></div>`
    })
    .join('')
}

export function renderPage({ graph, versions, current, diff, linkPrefix = './' }) {
  const meta = graph.meta
  const versionOptions = versions
    .map((version) => `<option value="${esc(version)}"${version === current ? ' selected' : ''}>${esc(version)}</option>`)
    .join('')

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>架构快照 ${esc(current)} · DSH Mobile</title>
<style>
  :root {
    --bg: #0f1115; --panel: #171a21; --line: #262b36; --ink: #e6e9ef; --muted: #8b93a3;
    --accent: #6ea8fe; --warn: #ff6b6b; --ok: #4ade80; --heur: #f0b849;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
    font: 14px/1.6 -apple-system, "PingFang SC", "Helvetica Neue", Arial, sans-serif; }
  header { padding: 16px 20px 12px; border-bottom: 1px solid var(--line); position: sticky; top: 0;
    background: rgba(15,17,21,.94); backdrop-filter: blur(8px); z-index: 10; }
  h1 { font-size: 17px; margin: 0 0 6px; font-weight: 600; }
  .meta { color: var(--muted); font-size: 12px; display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: center; }
  .badge { display: inline-block; padding: 1px 7px; border: 1px solid var(--line); border-radius: 99px; font-size: 11px; color: var(--muted); }
  .badge.warn { color: var(--warn); border-color: #4a2626; }
  .badge.ok { color: var(--ok); border-color: #1f3d2a; }
  .toolbar { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; margin-top: 10px; font-size: 13px; }
  .toolbar button { background: var(--panel); color: var(--ink); border: 1px solid var(--line);
    border-radius: 7px; padding: 4px 12px; cursor: pointer; font-size: 13px; }
  .toolbar button[aria-pressed="true"] { border-color: var(--accent); color: var(--accent); }
  .toolbar label { display: inline-flex; align-items: center; gap: 6px; color: var(--muted); }
  select { background: var(--panel); color: var(--ink); border: 1px solid var(--line); border-radius: 7px; padding: 4px 8px; }
  main { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 0; align-items: start; }
  @media (max-width: 1100px) { main { grid-template-columns: 1fr; } }
  #canvas { overflow: auto; padding: 16px; min-height: 420px; }
  #detail { border-left: 1px solid var(--line); padding: 16px; position: sticky; top: 106px;
    max-height: calc(100vh - 122px); overflow: auto; }
  @media (max-width: 1100px) { #detail { position: static; max-height: none; border-left: 0; border-top: 1px solid var(--line); } }
  #detail h3 { margin: 0 0 8px; font-size: 14px; }
  #detail dl { margin: 0 0 12px; display: grid; grid-template-columns: 88px 1fr; gap: 4px 10px; font-size: 13px; }
  #detail dt { color: var(--muted); }
  #detail dd { margin: 0; word-break: break-all; }
  #detail ul { margin: 4px 0 12px; padding-left: 16px; font-size: 13px; }
  #detail code { color: var(--accent); }
  section.block { border-top: 1px solid var(--line); padding: 16px 20px; }
  section.block h2 { font-size: 14px; margin: 0 0 10px; font-weight: 600; }
  .muted { color: var(--muted); }
  .diff { list-style: none; padding: 0; margin: 0; font-size: 13px; }
  .diff li { padding: 2px 0; }
  .diff .add { color: var(--ok); }
  .diff .del { color: var(--warn); }
  .diff em { color: var(--muted); font-style: normal; }
  .cycle { margin-bottom: 10px; }
  .chain { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; font-size: 12px; color: var(--muted); }
  .chain code { color: var(--ink); background: var(--panel); padding: 1px 6px; border-radius: 5px; }
  .ext-group { margin-bottom: 12px; }
  .ext-group h4 { margin: 0 0 4px; font-size: 12px; color: var(--muted); font-weight: 500; }
  .ext-list { display: flex; flex-wrap: wrap; gap: 6px; }
  .ext-list code { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 1px 7px; font-size: 12px; }
  .ext-list .count { color: var(--muted); font-size: 11px; margin-left: -2px; }
  .legend { display: flex; flex-wrap: wrap; gap: 16px; font-size: 12px; color: var(--muted); }
  .legend b { color: var(--ink); font-weight: 500; }
  svg { display: block; }
  .node rect { fill: var(--panel); stroke: var(--line); rx: 8; }
  .node.sel rect { stroke: var(--accent); }
  .node text.title { fill: var(--ink); font-size: 12.5px; font-weight: 600; }
  .node text.sub { fill: var(--muted); font-size: 10.5px; }
  .node { cursor: pointer; }
  .edge { fill: none; stroke: #4a5568; stroke-width: 1.3; }
  .edge.heuristic { stroke: var(--heur); stroke-dasharray: 4 3; stroke-width: 1.1; }
  .edge.cyclic { stroke: var(--warn); stroke-width: 1.8; stroke-dasharray: 6 3; }
  .edge.dim { opacity: .12; }
  .band { fill: rgba(255,255,255,.018); stroke: var(--line); stroke-dasharray: 2 4; }
  .band-label { fill: var(--muted); font-size: 11px; letter-spacing: .04em; }
</style>
</head>
<body>
<header>
  <h1>DSH Mobile 架构快照</h1>
  <div class="meta">
    ${badge(current, 'ok')}
    <span>commit <code>${esc(meta.commit)}</code>${meta.dirty ? ` ${badge(`工作区有 ${meta.dirty} 处未提交改动`, 'warn')}` : ''}</span>
    <span>分支 <code>${esc(meta.branch)}</code></span>
    <span>生成于 ${esc(meta.generatedAt.replace('T', ' ').slice(0, 19))} UTC</span>
    <span>${meta.groupCount} 个模块 · ${meta.edgeCount} 条依赖边 · ${meta.fileCount} 个文件 · ${meta.lineCount.toLocaleString('en-US')} 行</span>
    ${meta.cycleCount ? badge(`${meta.cycleCount} 处循环`, 'warn') : badge('无循环', 'ok')}
    <label>版本 <select id="version">${versionOptions}</select></label>
  </div>
  <div class="toolbar">
    <button data-scope="all" aria-pressed="true">全部</button>
    <button data-scope="ios-app" aria-pressed="false">iOS App</button>
    <button data-scope="ios-kit" aria-pressed="false">iOS Kit</button>
    <button data-scope="js" aria-pressed="false">JS / Node</button>
    <button data-scope="py" aria-pressed="false">Python</button>
    <label><input type="checkbox" id="showHeuristic" checked> 显示启发式边（类型引用，可能有误）</label>
    <label><input type="checkbox" id="cyclesOnly"> 只看环</label>
    <label><input type="checkbox" id="groupByLayer" checked> 按层分带</label>
  </div>
</header>
<main>
  <div id="canvas"><svg id="graph"></svg></div>
  <div id="detail"><p class="muted">点一个模块看它的文件、类型与依赖关系。</p></div>
</main>
<section class="block">
  <h2>循环依赖</h2>
  ${cycleSection(graph)}
</section>
<section class="block">
  <h2>与上一版相比</h2>
  ${diffSection(diff)}
</section>
<section class="block">
  <h2>外部依赖（只在统计里，不画进图）</h2>
  ${externalSection(graph)}
</section>
<section class="block">
  <h2>这张图的口径</h2>
  <div class="legend">
    <span><b>实线灰</b>：权威边界。Swift <code>import</code> 自有模块、SPM target 依赖、JS/Python 的相对 import。</span>
    <span><b>黄虚线</b>：启发式。Swift 跨目录的<b>类型引用</b>，靠类型名匹配得出，会漏也会误，可一键关掉。</span>
    <span><b>红虚线</b>：循环依赖。</span>
  </div>
  <p class="muted" style="margin-top:10px">
    扫描口径：SPM 目标依赖来自 <code>swift package describe</code>（${esc(meta.swiftDescribe)}）。
    启发式边已剔除注释与字符串，并要求类型出现在标注、泛型、构造调用等语法位置；
    库模块反向依赖 App 这类结构性不可能的边被直接丢弃${meta.droppedEdges?.length ? `（本次丢弃 ${meta.droppedEdges.length} 条）` : ''}。
    模块内文件之间的依赖不画，只计入模块规模。
  </p>
</section>
<script id="graph-data" type="application/json">${JSON.stringify(graph).replace(/</g, '\\u003c')}</script>
<script>
const graph = JSON.parse(document.getElementById('graph-data').textContent)
const LAYERS = ${JSON.stringify(LAYER_LABEL)}
const LINK_PREFIX = ${JSON.stringify(linkPrefix)}
const NODE_W = 210, NODE_H = 56, GAP_X = 250, GAP_Y = 78, PAD = 24
let scope = 'all'
let selected = null

const svg = document.getElementById('graph')
const detail = document.getElementById('detail')
const showHeuristic = document.getElementById('showHeuristic')
const cyclesOnly = document.getElementById('cyclesOnly')

function visibleEdges() {
  return graph.edges.filter((edge) => {
    if (edge.kind === 'heuristic' && !showHeuristic.checked) return false
    if (cyclesOnly.checked && !edge.cyclic) return false
    return true
  })
}

function visibleNodes() {
  const keep = new Set()
  for (const edge of visibleEdges()) { keep.add(edge.from); keep.add(edge.to) }
  return graph.nodes.filter((node) => {
    if (scope !== 'all' && node.layer !== scope) return false
    if (cyclesOnly.checked) return keep.has(node.id)
    return true
  })
}

/** 列式分层：按最长路径把节点排进列，环内的边不参与排序。 */
const LAYER_ORDER = ['ios-app', 'ios-kit', 'js', 'py']
const BAND_GAP = 34

function layout(nodes, edges, groupByLayer) {
  const positions = new Map()
  const bands = []
  const layerKeys = groupByLayer
    ? LAYER_ORDER.filter((layer) => nodes.some((node) => node.layer === layer))
    : ['*']
  let yBase = PAD
  let width = 0
  for (const layer of layerKeys) {
    const list = nodes.filter((node) => (groupByLayer ? node.layer === layer : true))
    const ids = new Set(list.map((node) => node.id))
    // 分层只在带内算：跨带边不参与排名，否则某一带的节点会被推到带外去
    const rank = new Map(list.map((node) => [node.id, 0]))
    const forward = edges.filter((edge) => ids.has(edge.from) && ids.has(edge.to) && !edge.cyclic)
    for (let pass = 0; pass < list.length; pass += 1) {
      let changed = false
      for (const edge of forward) {
        const next = (rank.get(edge.from) ?? 0) + 1
        if (next > (rank.get(edge.to) ?? 0)) { rank.set(edge.to, next); changed = true }
      }
      if (!changed) break
    }
    const columns = new Map()
    for (const node of list) {
      const column = rank.get(node.id) ?? 0
      if (!columns.has(column)) columns.set(column, [])
      columns.get(column).push(node)
    }
    let rows = 1
    let maxColumn = 0
    for (const [column, items] of columns) {
      rows = Math.max(rows, items.length)
      maxColumn = Math.max(maxColumn, column)
    }
    for (const [column, items] of columns) {
      items.sort((a, b) => b.lines - a.lines)
      const offset = (rows - items.length) / 2
      items.forEach((node, index) => {
        positions.set(node.id, { x: PAD + 20 + column * GAP_X, y: yBase + 20 + (index + offset) * GAP_Y })
      })
    }
    const bandWidth = PAD * 2 + 40 + maxColumn * GAP_X + NODE_W
    width = Math.max(width, bandWidth)
    bands.push({ layer, y: yBase, width: bandWidth, height: rows * GAP_Y + 34 })
    yBase += rows * GAP_Y + 34 + BAND_GAP
  }
  return { positions, bands, width: width + PAD }
}

function render() {
  const nodes = visibleNodes()
  const edges = visibleEdges().filter((edge) => nodes.some((n) => n.id === edge.from) && nodes.some((n) => n.id === edge.to))
  const groupByLayer = document.getElementById('groupByLayer').checked
  const { positions, bands, width } = layout(nodes, edges, groupByLayer)
  const height = bands.length ? bands[bands.length - 1].y + bands[bands.length - 1].height + PAD : PAD * 2
  svg.setAttribute('width', width)
  svg.setAttribute('height', height)
  const parts = []
  parts.push('<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#4a5568"/></marker><marker id="arrow-warn" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#ff6b6b"/></marker></defs>')
  for (const band of bands) {
    if (band.layer === '*') continue
    parts.push('<rect class="band" x="8" y="' + band.y + '" width="' + (width - 16) + '" height="' + band.height + '" rx="10"></rect>')
    parts.push('<text class="band-label" x="18" y="' + (band.y + 15) + '">' + (LAYERS[band.layer] || band.layer) + '</text>')
  }
  for (const edge of edges) {
    const a = positions.get(edge.from), b = positions.get(edge.to)
    if (!a || !b) continue
    const x1 = a.x + NODE_W, y1 = a.y + NODE_H / 2
    const x2 = b.x, y2 = b.y + NODE_H / 2
    const dx = Math.max(40, Math.abs(x2 - x1) / 2)
    const className = ['edge', edge.kind === 'heuristic' ? 'heuristic' : '', edge.cyclic ? 'cyclic' : '',
      selected && selected !== edge.from && selected !== edge.to ? 'dim' : ''].filter(Boolean).join(' ')
    const marker = edge.cyclic ? 'arrow-warn' : 'arrow'
    parts.push('<path class="' + className + '" marker-end="url(#' + marker + ')" d="M ' + x1 + ' ' + y1 +
      ' C ' + (x1 + dx) + ' ' + y1 + ', ' + (x2 - dx) + ' ' + y2 + ', ' + x2 + ' ' + y2 + '"><title>' +
      edge.from + ' → ' + edge.to + '（' + (edge.kind === 'heuristic' ? '启发式' : '权威') + '）' + (edge.samples?.length ? '｜' + edge.samples.join('；') : '') + '</title></path>')
  }
  for (const node of nodes) {
    const p = positions.get(node.id)
    const label = node.id.split('/').slice(-1)[0]
    const group = node.id.split('/').slice(0, -1).join('/')
    parts.push('<g class="node' + (selected === node.id ? ' sel' : '') + '" data-id="' + node.id + '" transform="translate(' + p.x + ',' + p.y + ')">' +
      '<rect width="' + NODE_W + '" height="' + NODE_H + '" rx="8"></rect>' +
      '<text class="title" x="12" y="23">' + label + '</text>' +
      '<text class="sub" x="12" y="41">' + group + ' · ' + node.files + ' 文件 · ' + node.lines.toLocaleString('en-US') + ' 行</text></g>')
  }
  svg.innerHTML = parts.join('')
  svg.querySelectorAll('.node').forEach((element) => {
    element.addEventListener('click', () => {
      selected = selected === element.dataset.id ? null : element.dataset.id
      render(); showDetail(selected)
    })
  })
}

function showDetail(id) {
  if (!id) { detail.innerHTML = '<p class="muted">点一个模块看它的文件、类型与依赖关系。</p>'; return }
  const node = graph.nodes.find((item) => item.id === id)
  const out = graph.edges.filter((edge) => edge.from === id)
  const incoming = graph.edges.filter((edge) => edge.to === id)
  const list = (edges) => edges.length
    ? '<ul>' + edges.map((edge) => '<li><code>' + (edge.from === id ? edge.to : edge.from) + '</code> <span class="muted">' +
      (edge.kind === 'heuristic' ? '启发式' : '权威') + (edge.cyclic ? ' · 环' : '') + '</span></li>').join('') + '</ul>'
    : '<p class="muted">无</p>'
  detail.innerHTML = '<h3>' + node.id + '</h3>' +
    '<dl><dt>层</dt><dd>' + (LAYERS[node.layer] || node.layer) + '</dd>' +
    '<dt>目录</dt><dd><code>' + node.dir + '</code></dd>' +
    '<dt>规模</dt><dd>' + node.files + ' 文件 / ' + node.lines.toLocaleString('en-US') + ' 行</dd>' +
    '<dt>声明类型</dt><dd>' + node.types + '</dd>' +
    (node.swiftImports.length ? '<dt>import</dt><dd>' + node.swiftImports.join(', ') + '</dd>' : '') +
    (node.pyModules.length ? '<dt>import</dt><dd>' + node.pyModules.slice(0, 12).join(', ') + '</dd>' : '') + '</dl>' +
    '<h3>它依赖谁（' + out.length + '）</h3>' + list(out) +
    '<h3>谁依赖它（' + incoming.length + '）</h3>' + list(incoming)
}

document.querySelectorAll('[data-scope]').forEach((button) => {
  button.addEventListener('click', () => {
    scope = button.dataset.scope
    document.querySelectorAll('[data-scope]').forEach((other) => other.setAttribute('aria-pressed', String(other === button)))
    selected = null; render(); showDetail(null)
  })
})
showHeuristic.addEventListener('change', () => { selected = null; render(); showDetail(null) })
cyclesOnly.addEventListener('change', () => { selected = null; render(); showDetail(null) })
document.getElementById('groupByLayer').addEventListener('change', () => { selected = null; render(); showDetail(null) })
document.getElementById('version').addEventListener('change', (event) => {
  location.href = LINK_PREFIX + event.target.value + '/index.html'
})
render()
</script>
</body>
</html>
`
}

export { LAYER_LABEL }
