/**
 * L2 Linux 容器渠道（脚手架）。
 *
 * 渠道本体（起容器、复制进卷、卷内执行、取回证据）在 T018/T019 落地；现在只提供
 * 自检与"不可用"的如实报告——**渠道不可用必须报 blocked，不得静默跳过**
 * （CI 里 Caddy 装不上导致 skip 反而更绿，是这条的由来）。
 *
 * 选型与前提见 `specs/006-verify-lanes/research.md` 决策 1。
 */

import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

export const lane = {
  id: 'l2',
  title: 'Linux 容器',
  isolation: 'Linux guest 内的容器卷；代码复制进卷（docker cp / COPY），不用共享挂载',
  requiresCopyIn: true,
  doctor: doctorL2,
  scenarios: {},
}

/** 自检只跑得起的部分：CLI 在不在、VM 起没起、镜像源配没配。 */
export function doctorL2({ env = process.env } = {}) {
  const checks = []
  const docker = whichBinary('docker')
  checks.push({
    name: 'docker CLI 在',
    ok: Boolean(docker),
    detail: docker ?? 'PATH 上找不到 docker',
    fix: docker ? undefined : 'brew install colima docker',
  })
  const colima = whichBinary('colima')
  checks.push({
    name: 'colima 在',
    ok: Boolean(colima),
    detail: colima ?? 'PATH 上找不到 colima',
    fix: colima ? undefined : 'brew install colima',
  })
  const status = docker ? run(docker, ['info', '--format', '{{.ServerVersion}} {{.Architecture}}']) : undefined
  checks.push({
    name: '容器运行时已启动',
    ok: Boolean(status && status.status === 0),
    detail: status?.stdout?.trim() || status?.stderr?.trim() || '未启动',
    fix: 'colima start --vm-type vz --mount-type virtiofs --cpu 4 --memory 6 --disk 60 --registry-mirror <mirror>',
  })
  const mirror = [env.DSH_LANE_REGISTRY_MIRROR, ...(readMirrors(env))].filter(Boolean)
  checks.push({
    name: '镜像源已配置（本机直连 Docker Hub 超时）',
    ok: mirror.length > 0,
    detail: mirror[0] ?? '未配置 registry-mirror 或 dockerd 代理',
    fix: '给 colima/dockerd 配镜像源或代理：直连 registry-1.docker.io 在本机超时',
  })
  const failed = checks.filter((check) => !check.ok)
  return {
    available: failed.length === 0,
    checks,
    blockedReason: failed.length > 0 ? failed.map((check) => check.name).join('、') : undefined,
    nextStep: failed.length > 0 ? failed.map((check) => check.fix).filter(Boolean).join('；') : undefined,
  }
}

function readMirrors(env) {
  const home = env.HOME
  if (!home) return []
  const file = `${home}/.colima/default/colima.yaml`
  try {
    const text = readFileSync(file, 'utf8')
    return (text.match(/registry-mirrors?:[\s\S]{0,300}?\]/) ?? []).map((match) => match.trim())
  } catch {
    return []
  }
}

function run(command, args) {
  return spawnSync(command, args, { encoding: 'utf8' })
}

function whichBinary(name) {
  const result = spawnSync('which', [name], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : undefined
}
