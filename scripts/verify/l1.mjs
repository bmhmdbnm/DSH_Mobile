/**
 * L1 同机隔离渠道：同一台 Mac、同一份二进制，靠临时 `HOME`/`DSH_HOME` 把
 * 会话、凭据、配对设备全部隔开。
 *
 * 为什么需要它：有些结论在本机"已经装好、已有身份"的状态下永远验不准
 * （例如"新装一个插件要不要重启宿主"），而用虚拟机验又太贵。临时 HOME 拿到的是
 * 同一份二进制，保真度高于容器。
 *
 * 纪律（宪法 III）：只**读**真实 `~/.dsh` 当作档案模板，绝不写；跑完要能证明
 * 真实数据没被动过（hash + mtime 对照），这条证明写进证据包的 `isolation.proof`。
 */

import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'

import { REPO_ROOT } from './matrix.mjs'

const PLUGIN_NAMES = ['dsh-plugin-mobile-link', 'dsh-plugin-send-image', 'dsh-plugin-doubao-image']
const ENDPOINT_WAIT_MS = 90_000
const POLL_MS = 500

export const lane = {
  id: 'l1',
  title: '同机隔离',
  isolation: '同一台 Mac、同一份二进制与代码；临时 HOME/DSH_HOME + 一次性档案',
  requiresCopyIn: false,
  doctor: doctorL1,
  scenarios: {
    smoke: { title: '隔离宿主能起来、连接器加载并发现宿主', run: smoke },
    'plugin-install-hot': { title: '新装一个插件是否需要重启宿主', run: pluginInstallHot },
    'desktop-instance': { title: '官方桌面版能否在隔离 HOME 下起第二个实例', run: desktopInstance },
  },
}

/** 自检：只查"现在能不能跑"，不装东西、不改环境。 */
export function doctorL1({ env = process.env } = {}) {
  const checks = []
  const dsh = whichBinary('dsh')
  checks.push({
    name: 'dsh 可执行',
    ok: Boolean(dsh),
    detail: dsh ?? 'PATH 上找不到 dsh',
    fix: dsh ? undefined : '装 DSH（`npm i -g @deepseek-ai/dsh`）或把它放进 PATH',
  })
  const realProfile = join(realDshHome(env), 'profiles', 'web')
  checks.push({
    name: '真实 web 档案可读（只当模板）',
    ok: existsSync(realProfile),
    detail: realProfile,
    fix: existsSync(realProfile) ? undefined : '先跑一次 `dsh web`，让它初始化档案',
  })
  const nodeMajor = Number(process.versions.node.split('.')[0])
  checks.push({
    name: 'Node ≥ 22',
    ok: nodeMajor >= 22,
    detail: process.versions.node,
    fix: nodeMajor >= 22 ? undefined : '用 Node 22 以上跑这个工具',
  })
  let tempOk = false
  let tempDetail = tmpdir()
  try {
    const probe = mkdtempSync(join(tmpdir(), 'lane-l1-doctor-'))
    writeFileSync(join(probe, 'probe'), 'ok')
    rmSync(probe, { recursive: true, force: true })
    tempOk = true
  } catch (error) {
    tempDetail = `${tmpdir()}: ${error.message}`
  }
  checks.push({
    name: '临时目录可写',
    ok: tempOk,
    detail: tempDetail,
    fix: tempOk ? undefined : '清一下临时目录或换个 TMPDIR',
  })
  const failed = checks.filter((check) => !check.ok)
  return {
    available: failed.length === 0,
    checks,
    blockedReason: failed.length > 0 ? failed.map((check) => check.name).join('、') : undefined,
    nextStep: failed.length > 0 ? failed.map((check) => check.fix).filter(Boolean).join('；') : undefined,
  }
}

/** 场景：起隔离宿主 → 等连接器写出 endpoint.json → 探一次端口 → 收尾对照。 */
async function smoke({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = []
  const commands = []
  let status = 'fail'
  let note
  let host

  try {
    seedProfile(dshHome)
    observations.push({ step: 'seed', fact: `隔离档案已就位：${join(dshHome, 'profiles', 'web')}` })
    host = spawnHost({ home, dshHome, outDir })
    log(`L1: 已起隔离宿主 pid=${host.pid}`)
    const probe = await probeHost(host, dshHome)
    observations.push(...probe.observations)
    status = probe.ok ? 'pass' : 'fail'
    note = probe.note
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
    const tail = stderrTail(host)
    if (tail) observations.push({ step: 'stderr', fact: `宿主 stderr 末尾：\n${tail}`, evidence: 'host.stderr.log' })
  } finally {
    return await finishSmoke({ host, before, observations, commands, root, status, note })
  }
}

/** 收尾：停宿主、对照真实数据、组装返回给上层的四态结果。 */
async function finishSmoke({ host, before, observations, commands, root, status, note }) {
  if (host) await stopHost(host)
  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  observations.push({ step: 'isolation', fact: untouched ? '真实 agent.json 未变' : '真实 agent.json 变了' })
  commands.push({
    argv: host?.argv ?? ['dsh', '--profile', 'web', '--no-open', '--port', '0'],
    exitCode: host?.laneExitCode ?? -1,
    stdoutPath: host?.stdoutPath,
    stderrPath: host?.stderrPath,
    note: '隔离宿主（收尾后退出码）',
  })
  rmSync(root, { recursive: true, force: true })
  return {
    status,
    note,
    observations,
    commands,
    isolation: {
      dshHome: host?.laneDshHome ?? '(未起环境)',
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（sha256 + mtime）`,
    },
  }
}

/**
 * 场景：新装一个插件是否需要重启宿主。
 *
 * 做法：一次性档案里把 mobile-link 摘干净（bundles + dependencies + node_modules 链接），
 * 起宿主 → 确认它确实没挂上（等不到 endpoint.json）→ 用**官方 CLI**
 * （`dsh plugin --profile web add <路径>`）装它 → **不重启**，看它是否自己挂上。
 *
 * 判定：装完后 endpoint.json 出现且宿主 pid 没变 → `pass`（不需要重启）；
 * 超时没出现 → `fail`（这个路径需要重启）；宿主退出过 → `fail`（等于重启过，不算数）。
 */
async function pluginInstallHot({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = []
  const commands = []
  let host
  let status = 'fail'
  let note

  try {
    const pluginDir = join(REPO_ROOT, 'plugins', 'mobile-link')
    seedProfile(dshHome, { stripPlugins: ['dsh-plugin-mobile-link'] })
    observations.push({ step: 'seed', fact: '一次性档案已就位，并从 bundles / dependencies / node_modules 里摘掉 dsh-plugin-mobile-link' })
    host = spawnHost({ home, dshHome, outDir })
    log(`L1: 隔离宿主 pid=${host.pid}（插件未装）`)
    if (await hasEndpoint(dshHome, 6000)) throw new Error('基准不对：插件在装之前就已经挂上，档案没摘干净')
    observations.push({ step: 'baseline', fact: '装之前连接器没有挂上（endpoint.json 不在）' })

    const install = installPlugin({ home, dshHome, pluginDir, outDir })
    commands.push({ argv: install.argv, exitCode: install.code, stdoutPath: install.logPath, note: '官方安装路径（dsh plugin add）' })
    observations.push({ step: 'install', fact: `dsh plugin --profile web add 退出码 ${install.code}`, evidence: 'install.log' })
    if (install.code !== 0) throw new Error(`安装失败（exit ${install.code}），看 ${install.logPath}`)

    const mounted = await hasEndpoint(dshHome, 60_000)
    const alive = host.laneExitCode === null || host.laneExitCode === undefined
    observations.push({
      step: 'after-install',
      fact: `不重启的情况下：连接器${mounted ? '自己挂上了' : '仍未挂上'}；宿主进程${alive ? '没退出（未重启）' : '退出过'}`,
      evidence: 'host.stderr.log',
    })
    status = mounted && alive ? 'pass' : 'fail'
    if (!mounted) note = '装完 60 秒内没有挂上：这条安装路径需要重启宿主'
    else if (!alive) note = '插件挂上了但宿主进程退出过，等于重启过，不能算"不用重启"'
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
    const tail = stderrTail(host)
    if (tail) observations.push({ step: 'stderr', fact: `宿主 stderr 末尾：\n${tail}`, evidence: 'host.stderr.log' })
  } finally {
    return await finishSmoke({ host, before, observations, commands, root, status, note })
  }
}

/**
 * 场景：官方桌面版能否在隔离 `HOME` 下起第二个实例。
 *
 * 这条是矩阵里 `host-desktop × l1` 的 prerequisite：能起，L1 就能验桌面版宿主；
 * 起不来，那一格按 research 决策 2 的三层退路降级。判据是"新起的 `dsh-desktop-host`
 * 进程用的是**临时**档案目录"——只看"有新进程"不够，那可能只是复用/聚焦了旧实例。
 *
 * 安全：只杀**本次新出现**的进程与本次拉起的 App 进程；跑之前先记下已有的 pid，绝不碰。
 */
async function desktopInstance({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const existing = listDesktopHosts()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = [{ step: 'baseline', fact: `跑之前已有 ${existing.length} 个桌面版宿主进程（不动它们）` }]
  const commands = []
  let status = 'fail'
  let note
  let child
  try {
    const binary = desktopBinary()
    if (!existsSync(binary)) throw new Error(`找不到桌面版可执行文件：${binary}`)
    seedProfile(dshHome, { profile: 'desktop' })
    observations.push({ step: 'seed', fact: `临时 desktop 档案已就位：${join(dshHome, 'profiles', 'desktop')}` })
    const probe = await launchAndProbe({ binary, home, dshHome, existing, outDir, log })
    child = probe.child
    observations.push(...probe.observations)
    status = probe.isolated.length > 0 ? 'pass' : 'fail'
    if (status === 'fail') {
      note = probe.fresh.length === 0
        ? '隔离 HOME 下起不来第二个实例（单实例锁挡住或未启动）：桌面版在 L1 里不可用'
        : '起了新进程但没有用临时档案：说明它复用了真实档案，隔离不成立'
    }
    for (const entry of probe.fresh) {
      try {
        process.kill(entry.pid, 'SIGTERM')
      } catch { /* 已经退出 */ }
    }
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  } finally {
    if (child) child.kill('SIGTERM')
    commands.push({ argv: [desktopBinary()], exitCode: -1, note: '隔离 HOME 下拉起桌面版（收尾已终止）' })
    return await finishSmoke({ host: { laneExitCode: 0, laneDshHome: dshHome, argv: [desktopBinary()] }, before, observations, commands, root, status, note })
  }
}

/** 拉起桌面版、等 25 秒、看有没有新宿主；返回给上层做判定与收尾。 */
async function launchAndProbe({ binary, home, dshHome, existing, outDir, log }) {
  const child = spawn(binary, [], {
    env: { ...process.env, HOME: home, DSH_HOME: dshHome },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const out = []
  const err = []
  child.stdout.on('data', (chunk) => out.push(chunk))
  child.stderr.on('data', (chunk) => err.push(chunk))
  log(`L1: 已拉起桌面版（隔离 HOME）pid=${child.pid}`)
  await sleep(25_000)
  const fresh = listDesktopHosts().filter((entry) => !existing.some((old) => old.pid === entry.pid))
  const isolated = fresh.filter((entry) => entry.command.includes(dshHome))
  const observations = [{
    step: 'probe',
    fact: `25 秒后新出现 ${fresh.length} 个桌面版宿主进程，其中使用临时档案的有 ${isolated.length} 个`,
  }]
  for (const entry of fresh) observations.push({ step: 'fresh-host', fact: `pid=${entry.pid} ${entry.command.slice(0, 220)}` })
  writeFileSync(join(outDir, 'desktop.stdout.log'), Buffer.concat(out))
  writeFileSync(join(outDir, 'desktop.stderr.log'), Buffer.concat(err))
  return { child, fresh, isolated, observations }
}

function listDesktopHosts() {
  const result = spawnSync('ps', ['-eo', 'pid=,command='], { encoding: 'utf8' })
  return String(result.stdout ?? '').split('\n')
    .map((line) => /^\s*(\d+)\s+(.*)$/.exec(line))
    .filter((match) => match !== null && match[2].includes('dsh-desktop-host/lib/index.js'))
    .map((match) => ({ pid: Number(match[1]), command: match[2] }))
}

function desktopBinary() {
  return process.env.DSH_DESKTOP_BINARY || '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness'
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** 装之前有没有挂上：只等一小会儿，用来确认基准干净。 */
async function hasEndpoint(dshHome, timeoutMs) {
  try {
    await waitForEndpoint(dshHome, undefined, { timeoutMs })
    return true
  } catch {
    return false
  }
}

/** 走官方安装路径；stdout/stderr 落证据目录，别把判定建立在自己的手改上。 */
function installPlugin({ home, dshHome, pluginDir, outDir }) {
  const argv = ['dsh', 'plugin', '--profile', 'web', 'add', pluginDir]
  const result = spawnSync(argv[0], argv.slice(1), {
    encoding: 'utf8',
    timeout: 180_000,
    env: { ...process.env, HOME: home, DSH_HOME: dshHome },
  })
  const logPath = join(outDir, 'install.log')
  writeFileSync(logPath, `$ ${argv.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
  return { argv, code: result.status ?? -1, logPath }
}

/** 观测两件事：连接器有没有写出 endpoint.json、宿主端口活不活。 */
async function probeHost(host, dshHome) {
  const endpoint = await waitForEndpoint(dshHome, host)
  const observations = [{
    step: 'endpoint',
    fact: `连接器写出 endpoint.json：port=${endpoint.port}（说明插件已加载并完成进程内发现）`,
    evidence: 'host.stdout.log',
  }]
  const code = httpStatus(endpoint.port)
  const ok = [200, 302, 401].includes(code)
  observations.push({ step: 'probe', fact: `宿主端口应答 HTTP ${code}（401/200/302 视为活着）` })
  return { ok, note: ok ? undefined : `宿主端口返回 HTTP ${code}`, observations }
}

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

/**
 * 把档案里 `link:` 依赖改写成绝对路径，package.json 与 pnpm-lock.yaml 两处都要动。
 *
 * pnpm 把本地依赖写成相对档案目录的 `link:../../../..`：package.json 里是 `specifier`，
 * 锁文件里是 `version`，而 **node_modules 的软链是照锁文件的 `version` 建立的**。
 * 档案一复制，这些相对路径就指到临时目录外面，下一次 `dsh plugin add` 会让 pnpm 按锁文件
 * 重建一批断链，表现为"安装时报 cannot resolve profile bundle（还是别的、我没碰过的插件）"。
 */
function absolutizeLinks(profileDir, sourceDir) {
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

function absolutizeLockfile(lockPath, sourceDir) {
  if (!existsSync(lockPath)) return
  const text = readFileSync(lockPath, 'utf8')
  const rewritten = text.replace(/^(\s*version:\s*)link:(?!\/)(.+)$/gm,
    (_match, prefix, target) => `${prefix}link:${resolve(sourceDir, target.trim())}`)
  if (rewritten !== text) writeFileSync(lockPath, rewritten)
}

/** 把指定插件从这个一次性档案里摘干净：bundles 列表、dependencies 与 node_modules 链接。 */
function stripFromProfile(profileDir, names) {
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

function isSymlink(path) {
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

async function stopHost(host, { graceMs = 8000 } = {}) {
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
function stderrTail(host, { limit = 1200 } = {}) {
  const text = host?.laneStderrText?.() ?? ''
  return text.slice(-limit).trim()
}

function whichBinary(name) {  const result = spawnSync('which', [name], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : undefined
}

function realDshHome(env) {
  return env.DSH_HOME_REAL || join(env.HOME || homedir(), '.dsh')
}
