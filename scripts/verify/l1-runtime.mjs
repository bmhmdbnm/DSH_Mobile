/**
 * L1 的隔离运行时：临时 HOME/DSH_HOME、一次性档案、起停宿主、真实数据指纹。
 *
 * 与场景分文件是为了两层都读得动：这里只回答"怎么把环境搭起来、怎么收干净"，
 * "验什么、怎么判"在 `l1-scenarios.mjs`。
 */

import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'

import { REPO_ROOT } from './matrix.mjs'

export const PLUGIN_NAMES = ['dsh-plugin-mobile-link', 'dsh-plugin-send-image', 'dsh-plugin-doubao-image']
export const ENDPOINT_WAIT_MS = 90_000
const POLL_MS = 500

/** 把真实档案复制成一次性档案；插件符号链接改写成绝对路径（复制会让相对链接失效）。 */
export function seedProfile(dshHome, { env = process.env, repo = REPO_ROOT, stripPlugins = [], profile = 'web' } = {}) {
  const source = join(realDshHome(env), 'profiles', profile)
  const target = join(dshHome, 'profiles', profile)
  mkdirSync(join(dshHome, 'profiles'), { recursive: true })
  cpSync(source, target, { recursive: true, verbatimSymlinks: true, dereference: false })
  const modules = join(target, 'node_modules')
  for (const name of PLUGIN_NAMES) {
    const link = join(modules, name)
    // 注意：复制之后这些相对链接已经断了，`existsSync` 会返回 false。
    // 必须用 lstat 判断"链接本身在不在"，否则改写被静默跳过，宿主起得来但插件全被跳过。
    if (!isSymlink(link)) continue
    const pluginDir = join(repo, 'plugins', name.replace('dsh-plugin-', ''))
    if (!existsSync(pluginDir)) continue
    unlinkSync(link)
    symlinkSync(pluginDir, link)
  }
  if (stripPlugins.length > 0) stripFromProfile(target, stripPlugins)
  absolutizeLinks(target, source)
  return target
}

/** 把指定插件从这个一次性档案里摘干净：bundles 列表、dependencies 与 node_modules 链接。 */
export function stripFromProfile(profileDir, names) {
  const manifestPath = join(profileDir, 'package.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  const profile = manifest.dsh?.profile ?? {}
  manifest.dsh = { ...manifest.dsh, profile: { ...profile, bundles: (profile.bundles ?? []).filter((name) => !names.includes(name)) } }
  for (const name of names) {
    if (manifest.dependencies) delete manifest.dependencies[name]
    const link = join(profileDir, 'node_modules', name)
    if (isSymlink(link)) unlinkSync(link)
  }
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
}

/**
 * 把档案里 `link:` 依赖改写成绝对路径，package.json 与 pnpm-lock.yaml 两处都要动。
 *
 * pnpm 把本地依赖写成相对档案目录的 `link:../../../..`：package.json 里是 `specifier`，
 * 锁文件里是 `version`，而 **node_modules 的软链是照锁文件的 `version` 建立的**。
 * 档案一复制，这些相对路径就指到临时目录外面，下一次 `dsh plugin add` 会让 pnpm 按锁文件
 * 重建一批断链，表现为"安装时报 cannot resolve profile bundle（还是别的、我没碰过的插件）"。
 */
export function absolutizeLinks(profileDir, sourceDir) {
  const manifestPath = join(profileDir, 'package.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  const dependencies = manifest.dependencies ?? {}
  let changed = false
  for (const [name, spec] of Object.entries(dependencies)) {
    if (typeof spec !== 'string' || !spec.startsWith('link:')) continue
    const target = spec.slice('link:'.length)
    if (isAbsolute(target)) continue
    dependencies[name] = `link:${resolve(sourceDir, target)}`
    changed = true
  }
  if (changed) {
    manifest.dependencies = dependencies
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  }
  absolutizeLockfile(join(profileDir, 'pnpm-lock.yaml'), sourceDir)
}

export function absolutizeLockfile(lockPath, sourceDir) {
  if (!existsSync(lockPath)) return
  const text = readFileSync(lockPath, 'utf8')
  const rewritten = text.replace(/^(\s*version:\s*)link:(?!\/)(.+)$/gm,
    (_match, prefix, target) => `${prefix}link:${resolve(sourceDir, target.trim())}`)
  if (rewritten !== text) writeFileSync(lockPath, rewritten)
}

export function isSymlink(path) {
  try {
    lstatSync(path)
    return true
  } catch {
    return false
  }
}

/** 起隔离宿主：`dsh --profile web --no-open --port 0`，stdout/stderr 落到证据目录。 */
export function spawnHost({ home, dshHome, outDir, env = process.env }) {
  const argv = ['dsh', '--profile', 'web', '--no-open', '--port', '0']
  const stdoutPath = join(outDir, 'host.stdout.log')
  const stderrPath = join(outDir, 'host.stderr.log')
  const childEnv = { ...env, HOME: home, DSH_HOME: dshHome }
  delete childEnv.DSH_WEB_URL
  const child = spawn(argv[0], argv.slice(1), { env: childEnv, stdio: ['ignore', 'pipe', 'pipe'] })
  const out = []
  const err = []
  child.laneExitCode = null
  child.stdout.on('data', (chunk) => out.push(chunk))
  child.stderr.on('data', (chunk) => err.push(chunk))
  child.on('exit', (code) => {
    child.laneExitCode = code
    writeFileSync(stdoutPath, Buffer.concat(out))
    writeFileSync(stderrPath, Buffer.concat(err))
  })
  child.stdoutPath = stdoutPath
  child.stderrPath = stderrPath
  child.argv = argv
  child.laneDshHome = dshHome
  // 进程还在跑时文件还没落盘，诊断要读内存里这份。
  child.laneStderrText = () => Buffer.concat(err).toString('utf8')
  child.laneStdoutText = () => Buffer.concat(out).toString('utf8')
  return child
}

/** 等连接器写出 endpoint.json；宿主提前退出则立刻失败，不空等到超时。 */
export async function waitForEndpoint(dshHome, host, { timeoutMs = ENDPOINT_WAIT_MS } = {}) {
  const file = join(dshHome, 'mobile-link', 'endpoint.json')
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (existsSync(file)) {
      const raw = JSON.parse(readFileSync(file, 'utf8'))
      if (raw.port && raw.url) return raw
    }
    if (host?.laneExitCode !== null && host?.laneExitCode !== undefined) {
      throw new Error(`隔离宿主提前退出（exit ${host.laneExitCode}），看 ${host.stderrPath}`)
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_MS))
  }
  throw new Error(`${timeoutMs}ms 内没等到 ${file}——连接器可能没加载，看 ${host?.stderrPath}`)
}

/** 探宿主端口；`/` 在无令牌时是 401，端口是死的则是 000。 */
export function httpStatus(port, { path = '/', timeoutSec = 3 } = {}) {
  const result = spawnSync('curl', ['-s', '-o', '/dev/null', '-m', String(timeoutSec), '-w', '%{http_code}',
    `http://127.0.0.1:${port}${path}`], { encoding: 'utf8' })
  return Number(result.stdout?.trim() ?? 0)
}

/** 真实数据的指纹：agent.json 的 sha256 + mtime（跑前跑后必须一致）。 */
export function snapshotRealData({ env = process.env, devices = [] } = {}) {
  const agent = join(realDshHome(env), 'mobile-link', 'agent.json')
  let digest = 'no-agent.json'
  if (existsSync(agent)) {
    const bytes = readFileSync(agent)
    digest = `sha256:${createHash('sha256').update(bytes).digest('hex').slice(0, 16)} mtime:${statSync(agent).mtimeMs}`
  }
  return { digest, devices }
}

export async function stopHost(host, { graceMs = 8000 } = {}) {
  if (host.laneExitCode !== null && host.laneExitCode !== undefined) return host.laneExitCode
  host.kill('SIGTERM')
  const deadline = Date.now() + graceMs
  while (Date.now() < deadline) {
    if (host.laneExitCode !== null && host.laneExitCode !== undefined) return host.laneExitCode
    await new Promise((resolve) => setTimeout(resolve, 200))
  }
  host.kill('SIGKILL')
  await new Promise((resolve) => setTimeout(resolve, 300))
  return host.laneExitCode ?? -1
}

/** 宿主 stderr 末尾——失败时最有用的一段（例如"跳过某个 profile bundle"）。 */
export function stderrTail(host, { limit = 1200 } = {}) {
  const text = host?.laneStderrText?.() ?? ''
  return text.slice(-limit).trim()
}

export function whichBinary(name) {
  const result = spawnSync('which', [name], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : undefined
}

export function realDshHome(env) {
  return env.DSH_HOME_REAL || join(env.HOME || homedir(), '.dsh')
}

export function listDesktopHosts() {
  const result = spawnSync('ps', ['-eo', 'pid=,command='], { encoding: 'utf8' })
  return String(result.stdout ?? '').split('\n')
    .map((line) => /^\s*(\d+)\s+(.*)$/.exec(line))
    .filter((match) => match !== null && match[2].includes('dsh-desktop-host/lib/index.js'))
    .map((match) => ({ pid: Number(match[1]), command: match[2] }))
}

export function desktopBinary() {
  return process.env.DSH_DESKTOP_BINARY || '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
