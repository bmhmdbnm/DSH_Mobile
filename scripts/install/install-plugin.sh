#!/usr/bin/env bash
# Register a DSH plugin with the local harness profile(s).
#
# Editing the profile by hand is what this replaces: the bundle list and the
# link dependency have to agree, and a plugin that is linked but not listed in
# `dsh.profile.bundles` fails silently — it installs and then never loads.
#
# A plugin that is listed but declares no `dsh.bundle.patch` is worse than
# silent: every boot fails with "declares no dsh.bundle in its package.json",
# which takes the harness down with it, so the desktop app cannot start either.
# Both halves are checked below before anything is written to a profile.
#
# 为什么默认装两个档案（004）：官方桌面版用 `profiles/desktop`，命令行 web 版用
# `profiles/web`，两边的插件登记互相独立。只装 web 的那段时间里，桌面版靠手工登记；
# 一旦重装或换机，手机连接器就从桌面宿主里消失。所以默认两个都装，谁存在装谁。
#
# Usage: scripts/install/install-plugin.sh [plugin-dir ...]
#        (default: every plugin under plugins/)
#        PLUGIN_PROFILE_DIR=<dir>  只装指定档案（隔离测试用）
#
# 不要用 `DSH_PROFILE_DIR` 当这个开关：那是**宿主自己的**变量（DSH 会把它设成当前档案，
# agent 的 shell 里就是 `profiles/desktop`），照抄它会让"装两个档案"悄悄变成"只装当前档案"。
# 实测踩过：04 脚本里写着 `DSH_PROFILE_DIR=${...}`，结果隔离测试改的是真实桌面档案。
#
# A restart of DSH is required afterwards; this script will not do it, because
# restarting takes the harness down.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"

step() { printf '\033[1;36m>>>\033[0m %s\n' "$1"; }

# 档案清单：显式指定 > 两个标准档案里存在的那几个。
PROFILES=()
if [ -n "${PLUGIN_PROFILE_DIR:-}" ]; then
  PROFILES=("$PLUGIN_PROFILE_DIR")
else
  for name in web desktop; do
    dir="$DSH_HOME_DIR/profiles/$name"
    if [ -f "$dir/package.json" ]; then
      PROFILES+=("$dir")
    else
      echo "跳过档案 ${name}：${dir} 不存在（该宿主没装过；桌面版只能用应用自带的 dsh 装）" >&2
    fi
  done
fi

if [ "${#PROFILES[@]}" -eq 0 ]; then
  echo "找不到任何 profile（看了 $DSH_HOME_DIR/profiles/{web,desktop}）" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  PLUGINS=("$@")
else
  PLUGINS=()
  for dir in "$REPO"/plugins/*/; do
    [ -f "$dir/package.json" ] && PLUGINS+=("$dir")
  done
fi

# 先整体体检，再动任何一个档案：一个没有 bundle patch 的插件会让**每次启动**都失败，
# 不能等到装了一半才发现。
step "体检 ${#PLUGINS[@]} 个插件"
for dir in "${PLUGINS[@]}"; do
  dir="${dir%/}"
  manifest="$dir/package.json"
  if [ ! -f "$manifest" ]; then
    echo "跳过（没有 package.json）: $dir" >&2
    continue
  fi
  name="$(node -p "require('$manifest').name")"
  node - "$manifest" "$dir" "$name" <<'NODE'
const [manifestPath, dir, name] = process.argv.slice(2)
const fs = require('node:fs')
const path = require('node:path')
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
const patch = manifest.dsh?.bundle?.patch
if (typeof patch !== 'string' || patch.length === 0) {
  console.error(`\u001b[1;31m✗\u001b[0m ${name} 的 package.json 没有 dsh.bundle.patch —— 登记进 dsh.profile.bundles 会让每次启动都失败。`)
  console.error(`  先补上 cordis.patch.yml（参考 plugins/send-image/cordis.patch.yml），再写：`)
  console.error(`  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }`)
  process.exit(1)
}
if (!fs.existsSync(path.resolve(dir, patch))) {
  console.error(`\u001b[1;31m✗\u001b[0m ${name} 的 dsh.bundle.patch 指向的 ${patch} 不存在。`)
  process.exit(1)
}
NODE
done

for PROFILE in "${PROFILES[@]}"; do
  step "档案 $(basename "$PROFILE")（${PROFILE}）"

  for dir in "${PLUGINS[@]}"; do
    dir="${dir%/}"
    manifest="$dir/package.json"
    [ -f "$manifest" ] || continue
    name="$(node -p "require('$manifest').name")"

    node - "$PROFILE/package.json" "$name" "$dir" <<'NODE'
const [profilePath, name, dir] = process.argv.slice(2)
const fs = require('node:fs')
const profile = JSON.parse(fs.readFileSync(profilePath, 'utf8'))

profile.dependencies ??= {}
profile.dependencies[name] = `link:${dir}`

profile.dsh ??= {}
profile.dsh.profile ??= {}
profile.dsh.profile.bundles ??= []
// Both halves are required: linked-but-unlisted installs and never loads.
if (!profile.dsh.profile.bundles.includes(name)) profile.dsh.profile.bundles.push(name)

fs.writeFileSync(profilePath, JSON.stringify(profile, null, 2) + '\n')
console.log(`  依赖: ${name} -> link:${dir}`)
console.log(`  bundles: ${profile.dsh.profile.bundles.join(', ')}`)
NODE
  done

  step "链接依赖（$(basename "$PROFILE")）"
  if command -v pnpm >/dev/null 2>&1; then
    (cd "$PROFILE" && pnpm install --silent)
  else
    (cd "$PROFILE" && npm install --silent)
  fi
done

step "完成（已处理的档案：$(printf '%s ' "${PROFILES[@]}" | xargs -n1 basename | tr '\n' ' '))"
echo "重启 DSH 后生效（插件在启动时加载）。官方桌面版：npm run restart；web 版：重启你的 dsh web。"
