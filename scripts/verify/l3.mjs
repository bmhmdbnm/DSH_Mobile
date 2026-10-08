/**
 * L3 macOS 客体 VM 渠道（脚手架）。
 *
 * 渠道本体（Tart 创建/启动/执行/销毁、guest 内跑"从零启用"）在 T022–T024 落地；
 * 现在只提供自检与"不可用"的如实报告。
 *
 * 选型见 `specs/006-verify-lanes/research.md` 决策 4：Tart（CLI 优先、可脚本化），
 * 备选 VirtualBuddy（GUI，只能手工走查）。
 */

import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const lane = {
  id: 'l3',
  title: 'macOS 客体 VM',
  isolation: 'Apple silicon 上的 macOS 客体虚拟机，与宿主环境完全隔离',
  requiresCopyIn: false,
  doctor: doctorL3,
  scenarios: {},
}

/** 自检：Tart 在不在、有没有可用的 guest 模板。 */
export function doctorL3({ env = process.env } = {}) {
  const checks = []
  const tart = whichBinary('tart')
  checks.push({
    name: 'tart 在',
    ok: Boolean(tart),
    detail: tart ?? 'PATH 上找不到 tart',
    fix: tart ? undefined : 'brew install cirruslabs/cli/tart',
  })
  const images = tart ? run(tart, ['list']) : undefined
  const templates = (images?.stdout ?? '').split('\n').map((line) => line.trim()).filter(Boolean)
  checks.push({
    name: '至少一个 macOS guest 模板',
    ok: templates.length > 0,
    detail: templates[0] ?? 'tart list 为空',
    fix: '准备一台干净 macOS guest（`tart clone` 自模板），一次性实例跑完即销毁',
  })
  const homedirOk = existsSync(join(env.HOME || homedir(), 'Library'))
  checks.push({
    name: '宿主 macOS 环境可读（用于比对"真实数据未动"）',
    ok: homedirOk,
    detail: env.HOME || homedir(),
    fix: homedirOk ? undefined : 'HOME 不可读，先修环境',
  })
  const failed = checks.filter((check) => !check.ok)
  return {
    available: failed.length === 0,
    checks,
    blockedReason: failed.length > 0 ? failed.map((check) => check.name).join('、') : undefined,
    nextStep: failed.length > 0 ? failed.map((check) => check.fix).filter(Boolean).join('；') : undefined,
  }
}

function run(command, args) {
  return spawnSync(command, args, { encoding: 'utf8', timeout: 20_000 })
}

function whichBinary(name) {
  const result = spawnSync('which', [name], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : undefined
}
