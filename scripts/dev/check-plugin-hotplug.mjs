#!/usr/bin/env node
/**
 * 热插拔契约的静态检查（003）。
 *
 * 只查两类**真实踩过**的缺陷，宁少勿滥——误报会让人关掉检查：
 *
 *   1. 模块顶层的定时器：`setInterval(...)` / `setTimeout(...)` 写在函数外，插件被禁用时没人清它，
 *      而且是全局句柄泄漏（进程不退出、回调继续跑）。
 *   2. 客户端 bundle 的第一条语句是顶层声明：经典脚本的 `const`/`let` 落在全局词法作用域，
 *      热重启用会让浏览器把同一个 URL 再执行一遍，第二次直接
 *      `Identifier '…' has already been declared` 抛语法错误——宿主只看到
 *      `loaded without registering`，表现是"禁用后再启用，入口再也不回来"（002 真踩过）。
 *
 * 动态行为（禁用了到底有没有撤干净）由各插件的 `test/hotplug.test.js` 负责，这里只管一眼能看出来的形状。
 * 退出码：0 = 干净，1 = 有发现。
 */

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = fileURLToPath(new URL('../..', import.meta.url))
const PLUGINS_DIR = join(ROOT, 'plugins')

/** 去掉注释（不解析字符串；这两类检查不需要那么精确）。 */
export function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^[ \t]*\/\/.*$/gm, '')
}

/** `lib/` 下的全部 .js / .mjs。 */
function sourceFiles(dir) {
  if (!existsSync(dir)) return []
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) return sourceFiles(path)
    return /\.(js|mjs)$/.test(name) ? [path] : []
  })
}

/**
 * 顶层（列 0）的定时器调用：函数体里的都缩进过，所以列 0 就是模块作用域。
 *
 * 只认两种形状——直接调用与赋值调用；`const sleep = (ms) => setTimeout(...)` 这种"顶层声明的
 * 函数里才调"不算（它没有句柄泄漏，禁用时也没有东西需要清）。
 */
export function topLevelTimers(source) {
  return source
    .split('\n')
    .flatMap((line, index) => {
      const match = /^(?:export\s+)?(?:(?:const|let|var)\s+[^=]+?=\s*)?(setInterval|setTimeout)\s*\(/.exec(line)
      return match === null ? [] : [{ line: index + 1, what: `模块顶层调了 ${match[1]}` }]
    })
}

/** 去注释之后的第一条代码行。 */
export function firstCodeLine(source) {
  return stripComments(source).split('\n').find((line) => line.trim().length > 0) ?? ''
}

/**
 * 客户端 bundle 的第一条语句是否是顶层声明。
 *
 * 经典脚本的 `const`/`let`/`function` 落在全局词法作用域：热重启用再执行一遍时，第二次会抛
 * `Identifier '…' has already been declared`。官方 bundle 的顶层只有一句
 * `window.__ModuleLoader__.load(...)`，所以"第一条代码不是声明"就是我们要的形状。
 */
export function startsWithDeclaration(source) {
  return /^(const|let|var|function|class)\s/.test(firstCodeLine(source).trim())
}

/** 客户端 bundle 的第一条语句不得是顶层声明（那会让整份脚本不可重入）。 */
function clientBundleShape(pluginDir, pkg) {
  if (pkg?.dsh?.client === undefined) return []
  const rel = pkg.exports?.['./client']
  if (typeof rel !== 'string') {
    return [{ file: join(pluginDir, 'package.json'), line: 1, what: '声明了 dsh.client 却没给 exports["./client"]' }]
  }
  const file = join(pluginDir, rel)
  if (!existsSync(file)) {
    return [{ file, line: 1, what: 'exports["./client"] 指向的文件不存在' }]
  }
  const first = firstCodeLine(readFileSync(file, 'utf8'))
  const declaration = startsWithDeclaration(first)
  return declaration
    ? [{ file, line: 1, what: `客户端 bundle 以顶层声明开头（${first.trim().slice(0, 40)}…）：整份脚本必须先用 IIFE 包起来，否则热重启用再执行一次会抛 "already been declared"` }]
    : []
}

function main() {
  const findings = []
  let scanned = 0
  for (const name of readdirSync(PLUGINS_DIR)) {
    const dir = join(PLUGINS_DIR, name)
    if (!statSync(dir).isDirectory()) continue
    const pkgPath = join(dir, 'package.json')
    if (!existsSync(pkgPath)) continue
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
    for (const file of sourceFiles(join(dir, 'lib'))) {
      scanned += 1
      findings.push(...topLevelTimers(readFileSync(file, 'utf8')).map((finding) => ({ ...finding, file })))
    }
    findings.push(...clientBundleShape(dir, pkg))
  }

  if (findings.length === 0) {
    console.log(`ok  热插拔契约（扫了 ${scanned} 个源文件）：没有模块顶层定时器，客户端 bundle 都可重入`)
    return 0
  }
  console.log(`发现 ${findings.length} 处热插拔形状问题：\n`)
  for (const finding of findings) {
    console.log(`  ${relative(ROOT, finding.file)}:${finding.line}  ${finding.what}`)
  }
  console.log('\n动态行为（禁用后有没有撤干净）另由 plugins/*/test/hotplug.test.js 覆盖。')
  return 1
}

// 只有被直接当成脚本跑时才执行；被 import（单测）时不能有副作用——这条检查自己也得守它的规矩。
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main())
}
