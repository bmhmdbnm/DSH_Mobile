#!/usr/bin/env bash
# Install everything this repository ships to the local machine.
#
# One entry point on purpose: installing the skill but forgetting the plugin —
# or the reverse — produces a half-working setup whose symptoms look like bugs.
# The connector and the skill only take effect after DSH restarts, and that step
# is called out rather than performed, because restarting takes the harness down.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

step() { printf '\n\033[1;36m>>>\033[0m %s\n' "$1"; }

step "1/4 安装 skill"
"$REPO/scripts/install/install-skills.sh"

step "2/4 注册插件"
"$REPO/scripts/install/install-plugin.sh"

step "3/4 打开源码热更（改插件源码不用重启）"
node "$REPO/scripts/dev/plugin-hmr.mjs" on

step "4/4 检查（两个宿主档案各查一遍）"
node -e "
const { existsSync } = require('node:fs')
const { homedir } = require('node:os')
const { join } = require('node:path')
const home = process.env.DSH_HOME || join(homedir(), '.dsh')
const wanted = ['dsh-plugin-mobile-link', 'dsh-plugin-send-image', 'dsh-plugin-doubao-image']
let failed = false
for (const profile of ['web', 'desktop']) {
  const manifest = join(home, 'profiles', profile, 'package.json')
  if (!existsSync(manifest)) {
    console.log(\`  ⏭  \${profile} 档案不存在（该宿主没装过）——跳过\`)
    continue
  }
  const bundles = JSON.parse(require('node:fs').readFileSync(manifest, 'utf8')).dsh.profile.bundles
  console.log(\`  \${profile}:\`)
  for (const name of wanted) {
    const linked = existsSync(join(home, 'profiles', profile, 'node_modules', name))
    const listed = bundles.includes(name)
    const ok = linked && listed
    console.log(\`    \${ok ? '✅' : '❌'} \${name}  已链接=\${linked} 已登记=\${listed}\`)
    if (!ok) failed = true
  }
}
const skill = join(home, 'skills', 'send-image', 'SKILL.md')
console.log(\`  \${existsSync(skill) ? '✅' : '❌'} skill send-image\`)
if (!existsSync(skill)) failed = true
if (failed) process.exitCode = 1
"

step "对等检查（两个档案的插件、bundle 与配置块）"
node "$REPO/scripts/dev/profile-parity.mjs" --report || true
echo "要让它对等检查真的把关：node $REPO/scripts/dev/profile-parity.mjs（有差异即非零退出）"

printf '\n\033[1;33m需要重启 DSH 才会生效\033[0m（插件与 skill 在启动时加载）。\n'
echo "重启一次之后：改插件源码（lib/*.js）保存即生效，不必再重启；新增/删除插件、改配置仍需重启。"
echo "关掉源码热更：node $REPO/scripts/dev/plugin-hmr.mjs off（同样要重启一次）"
echo "重启后验证：node $REPO/scripts/dev/dsh-probe.mjs status"
