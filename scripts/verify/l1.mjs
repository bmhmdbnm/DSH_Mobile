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
import { join } from 'node:path'

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
  scenarios: { smoke: { title: '隔离宿主能起来、连接器加载并发现宿主', run: smoke } },
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

/** 把真实 web 档案复制成一次性档案；插件符号链接改写成绝对路径（复制会让相对链接失效）。 */
export function seedProfile(dshHome, { env = process.env, repo = REPO_ROOT } = {}) {
  const source = join(realDshHome(env), 'profiles', 'web')
  const target = join(dshHome, 'profiles', 'web')
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
  return target
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
