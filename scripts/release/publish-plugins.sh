#!/usr/bin/env bash
#
# 把三个插件包发到 npm —— 一次跑完，失败即停。
#
#   scripts/release/publish-plugins.sh                 # 只自检 + 干跑，不发布
#   scripts/release/publish-plugins.sh --publish       # 真的发布（需要先 npm login）
#   scripts/release/publish-plugins.sh --publish --otp 123456   # 手里有 6 位码时
#   scripts/release/publish-plugins.sh --publish --only mobile-link
#   scripts/release/publish-plugins.sh --staged        # 只列 npm 上「待批准」的暂存版本
#
# 为什么要有这个脚本：
#   * 三个包的元数据必须一致（repository / homepage / bugs / keywords / files），
#     手工改容易漏一个，而 npm 上的元数据发出去就改不回来了（只能发新版本）。
#   * `dsh plugin add` 装的就是 npm 上的东西，包内容错了等于安装路径坏了——
#     所以发布前先 `npm pack` 干跑，把**将被打包的文件**逐个打出来。
#
# 前置：`npm login`（registry 指向 npmmirror 时，发布仍需登录 npmjs，见脚本尾部说明）。
#
# 踩过的坑，两次都花在同一个地方，写在这里省下一次：
#   1. `npm login --registry=…npmjs.org` 的 token 是**按 registry 存**的，所以每条命令
#      （whoami / view / publish）都必须显式带 --registry，否则会去问 npmmirror 那个只读镜像，
#      报「未登录」。脚本里已经统一成 ${NPM_REGISTRY}。
#   2. **不要用 `NPM_CONFIG__AUTH` 环境变量传 token**：它看起来生效（whoami 通过），但发布时
#      会被忽略，registry 回 401 `OTP required for authentication`，而 token 明明是带
#      bypass_2fa 的（可在 https://registry.npmjs.org/-/npm/v1/tokens 用 `bypass_2fa: true` 核实）。
#      可靠做法是把它写进 ~/.npmrc 的 `//registry.npmjs.org/:_authToken=…`。
#   3. 这个账号的 2FA 是 security key，没有 6 位码可填：`npm publish` 会回 EOTP，并在终端
#      打印一条认证链接（`Authenticate your account at: https://www.npmjs.com/auth/cli/<uuid>`）。
#      把那条链接换到手机浏览器打开、确认一下就行 —— CLI 是轮询 registry 的 doneUrl 拿凭据，
#      **不依赖本机浏览器回调**（2026-10-12 人不在电脑旁，三个包就是这么发完的）。
#      `--otp` 只在手里真有 6 位码时才有用。
#   4. **暂存发布（staged publishing）会挡住重发同一个版本号**：npm 先把版本放进「待批准」
#      队列，同名版本没被批准、也没被删掉之前，再发回 409
#      `Cannot publish over previously staged version`，而账号里那条暂存记录可能是几天前
#      留下的旧包（内容与这次要发的不一样）。所以本脚本发布前先查队列（`--staged` 也能
#      单独看），有同名记录就当场停下并打出 stage-id。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGES=(mobile-link send-image doubao-image)
#: 发布目标。本机 registry 指向 npmmirror（只读镜像），而 `npm login` 的 token 是按 registry
#: 存的，所以每条命令都要显式带上官方源，否则会命中镜像并报「未登录」。
NPM_REGISTRY="https://registry.npmjs.org"
PUBLISH=0
ONLY=""
OTP=""
STAGED_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    # 账号开了两步验证时，npm 要求每次发布带一次性验证码。三个包要在同一个 30 秒窗口里
    # 发完（本脚本按顺序发，通常够），所以码从命令行传进来，命令里不留痕。
    --otp) OTP="${2:-}"; shift 2 ;;
    --staged) STAGED_ONLY=1; shift ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'publish-plugins: 不认识的参数 %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m>>>\033[0m %s\n' "$*"; }
die() { printf 'publish-plugins: %s\n' "$*" >&2; exit 1; }

# 暂存队列在 registry 的 `/-/stage`，要凭据。token 直接从 ~/.npmrc 里读按 registry 存的那条
# （`npm config get //registry.npmjs.org/:_authToken` 在有的版本上会给不出来）。
staged_queue_json() {
  node -e '
    const fs = require("fs"), os = require("os")
    const rc = fs.readFileSync(os.homedir() + "/.npmrc", "utf8")
    const m = /\/\/registry\.npmjs\.org\/:_authToken\s*=\s*(\S+)/.exec(rc)
    if (!m) {
      console.error("~/.npmrc 里没有 registry.npmjs.org 的 _authToken —— 先 npm login --auth-type=web")
      process.exit(2)
    }
    fetch("https://registry.npmjs.org/-/stage?page=0&perPage=100", {
      headers: { Authorization: "Bearer " + m[1] },
    }).then(async (r) => {
      if (!r.ok) {
        console.error("查暂存队列失败：HTTP " + r.status + " " + (await r.text()).slice(0, 200))
        process.exit(2)
      }
      process.stdout.write(JSON.stringify(await r.json()))
    }).catch((e) => { console.error("查暂存队列失败：" + e.message); process.exit(2) })
  '
}

if [ "$STAGED_ONLY" = "1" ]; then
  say "npm 上的暂存版本（待批准）"
  staged_queue_json | node -e '
    let raw = ""
    process.stdin.on("data", (chunk) => { raw += chunk })
    process.stdin.on("end", () => {
      const { items = [], total = 0 } = JSON.parse(raw)
      if (!total) {
        console.log("  队列为空。")
        return
      }
      for (const item of items) {
        console.log(`  ${item.packageName}@${item.version}  id=${item.id}  暂存于 ${item.createdAt}  状态 ${item.status}`)
      }
      console.log("")
      console.log("  删掉一条：npm 升到 >=11.15 后 `npm stage reject <id>`；或 DELETE /-/stage/<id>（都要 2FA）。")
      console.log("  不要为了清路直接 approve —— 暂存的是**当时那份包**，未必等于现在要发的。")
    })'
  exit 0
fi

# ── 1. 每个包：元数据齐全 + 测试通过 + 打包内容正确 ─────────────────────────

for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  dir="$ROOT/plugins/$name"
  say "$name"

  node - "$dir/package.json" <<'NODE'
const [path] = process.argv.slice(2)
const data = require(path)
const need = ['name', 'version', 'description', 'keywords', 'license', 'author',
              'repository', 'homepage', 'bugs', 'files']
const missing = need.filter((key) => !data[key] || (Array.isArray(data[key]) && !data[key].length))
if (missing.length) {
  console.error(`  缺字段: ${missing.join(', ')}`)
  process.exit(1)
}
if (data.private === true) {
  console.error('  private: true —— npm 会拒绝发布')
  process.exit(1)
}
// `dsh plugin add` 的加载路径依赖这两个声明，缺一个装上去也不生效。
if (!data.dsh?.bundle?.patch) {
  console.error('  缺 dsh.bundle.patch —— 装上去不会成为 profile 的一层')
  process.exit(1)
}
if (!data.files.includes('cordis.patch.yml')) {
  console.error('  files 里没有 cordis.patch.yml —— 打出来的包里缺这个文件')
  process.exit(1)
}
console.log(`  ${data.name}@${data.version}  metadata ok`)
NODE

  ( cd "$dir" && npm test >/dev/null 2>&1 ) && printf '  tests ok\n' || die "$name 的测试没过"

  # What actually goes into the tarball, printed rather than assumed.
  ( cd "$dir" && npm pack --dry-run --json 2>/dev/null ) | node -e '
let raw = ""
process.stdin.on("data", (chunk) => { raw += chunk })
process.stdin.on("end", () => {
  const [info] = JSON.parse(raw)
  console.log(`  ${info.filename}  ${info.files.length} files  ${(info.size / 1024).toFixed(1)} KB`)
  for (const file of info.files) console.log(`    ${file.path}`)
  const wanted = ["package.json", "cordis.patch.yml", "README.md", "lib"]
  for (const item of wanted) {
    if (!info.files.some((file) => file.path === item || file.path.startsWith(`${item}/`))) {
      console.error(`  包里缺 ${item}`)
      process.exit(1)
    }
  }
})'
done

# ── 2. 名字有没有被占（发了才发现重名就白跑了） ─────────────────────────────

say "检查 npm 上的名字"
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  pkg="$(node -p "require('$ROOT/plugins/$name/package.json').name")"
  version="$(node -p "require('$ROOT/plugins/$name/package.json').version")"
  published="$(npm view "$pkg" version --registry="$NPM_REGISTRY" 2>/dev/null || true)"
  if [ -z "$published" ]; then
    printf '  %s：尚未发布，可以发 %s\n' "$pkg" "$version"
  elif [ "$published" = "$version" ]; then
    die "$pkg@$version 已经发过了 —— 先升 version 再发（npm 不允许覆盖已发布的版本）"
  else
    printf '  %s：线上是 %s，本次将发 %s\n' "$pkg" "$published" "$version"
  fi
done

# 同名版本已经躺在暂存队列里的话，发布一定回 409；提前拦下并把 stage-id 打出来，
# 免得把「归档/测试/打包」这一串都跑完才发现。检查本身只读，干跑时也只提示不拦。
say "检查 npm 上的暂存队列"
wanted=()
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  wanted+=("$(node -p "require('$ROOT/plugins/$name/package.json').name")@$(node -p "require('$ROOT/plugins/$name/package.json').version")")
done
staged_conflicts="$(staged_queue_json | node -e '
  let raw = ""
  process.stdin.on("data", (chunk) => { raw += chunk })
  process.stdin.on("end", () => {
    const { items = [] } = JSON.parse(raw)
    const want = new Set(process.argv.slice(1))
    for (const item of items) {
      const key = `${item.packageName}@${item.version}`
      if (want.has(key)) console.log(`${key}\t${item.id}\t${item.createdAt}`)
    }
  })' "${wanted[@]}")"

if [ -n "$staged_conflicts" ]; then
  while IFS="$(printf '\t')" read -r pkg id created; do
    printf '  %s 已在暂存队列（暂存于 %s，id=%s）\n' "$pkg" "$created" "$id"
  done <<<"$staged_conflicts"
  if [ "$PUBLISH" = "1" ]; then
    die "npm 上有同名暂存版本，发布会回 409 (Cannot publish over previously staged version)。
  先删掉上面那些记录再重跑（两种删法都要 2FA）：
    * npm 升到 >=11.15：npm stage reject <id>
    * 或调 registry：DELETE https://registry.npmjs.org/-/stage/<id>
  不要图省事直接 approve：暂存的是**当时那份包**，未必等于这次要发的版本。"
  fi
  printf '  干跑提醒：真发布前要先删掉这些暂存记录，否则会被 409 挡下。\n'
else
  printf '  队列里没有本次要发的版本。\n'
fi

if [ "$PUBLISH" != "1" ]; then
  say "干跑结束（没有发布）。要真的发：scripts/release/publish-plugins.sh --publish"
  cat <<'NOTE'

发布前确认：
  * 每条 npm 命令都显式带官方源：`--registry=https://registry.npmjs.org`。token 是**按
    registry 存**的（本机 registry 以前指向 npmmirror，现在 ~/.npmrc 里是官方源，但这条
    习惯仍然有效），不带时可能命中镜像并报「未登录」。
  * 三个包都没有 scope，所以不会遇到「scope 需要付费组织」的问题。
  * 真发布时 npm 会打印一条 `https://www.npmjs.com/auth/cli/<uuid>` 认证链接——换成手机
    浏览器打开确认即可，CLI 自己会轮询拿凭据。
  * 发完检查一遍：npm view <name> dist.tarball，再在一台干净机器上
    `dsh plugin --profile web add <name>` 走一次真实安装路径。
NOTE
  exit 0
fi

# ── 3. 发布 ────────────────────────────────────────────────────────────────

# The registry has to be named here too. `npm login --registry=…npmjs.org` stores the
# token **scoped to that registry** — so a bare `npm whoami` can end up asking a mirror,
# which has no credentials for it, and reports "not logged in" while the login is
# perfectly good. That false negative is what made the first run of this script
# stop right after a successful login.
# 凭据检查只做**打包**那半（`--dry-run`）：它证明包能装对，不证明能发上去。
# 为什么不用 `npm whoami`：本机那个 granular token 已于 2026-09-25 过期（npm 邮件
# 「[npm] Granular access tokens expired」，whoami 回 401），拿它当发布门槛只会劝退。
# 2026-10-12 实测走得通的发布路径是**网页认证**：`npm login --auth-type=web` 登录一次
# （手机浏览器就能完成，CLI 轮询 registry 的 doneUrl），之后 `npm publish` 再打印一条
# auth/cli 链接要一次 presence 确认。
# 三个包**各自**干跑一次。只验第一个包等于赌另外两个的 `files` 也写对了——而它们
# 是不同的清单（比如 send-image 必须带上 lib/send-image.mjs，否则装出来跑不了）。
# 打包都失败就没必要往下走，所以这里失败即 die。
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  if ! ( cd "$ROOT/plugins/$name" && npm publish --registry="$NPM_REGISTRY" --dry-run >/dev/null 2>&1 ); then
    die "打不出包（$name）：先看 npm pack 的输出"
  fi
  printf '  打包检查通过（%s）\n' "$name"
done
printf '  提醒：真发布需要交互式认证——npm 已收紧 bypass-2FA token；失败时先 npm login --auth-type=web\n'

say "发布"
# 累积式：脚本头是 `set -euo pipefail`，一个包发失败会让整脚本当场退出，
# 于是「谁已经发出去了」无从得知，剩下的也没机会发。三个包共用一个 30 秒 OTP
# 窗口，这个失败模式是现实会碰到的，所以这里自己收着错误、跑完再一起报。
published=()
failed=()
for name in "${PACKAGES[@]}"; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  if ( cd "$ROOT/plugins/$name" && npm publish --registry="$NPM_REGISTRY" --access public ${OTP:+--otp="$OTP"} ); then
    published+=("$name")
  else
    failed+=("$name")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf '\n已发布：%s；未发布：%s\n' \
    "$( [ "${#published[@]}" -gt 0 ] && (IFS=,; echo "${published[*]}") || echo '（无）' )" \
    "$(IFS=,; echo "${failed[*]}")"
  printf '未发布的多半是认证问题：npm login --auth-type=web 之后重跑本脚本（已发出去的包会被 npm 拒绝重发，属正常）。\n'
  printf '若报的是 409 / Cannot publish over previously staged version，那是暂存队列里还有同名版本：\n'
  printf '  scripts/release/publish-plugins.sh --staged 看 id，删掉之后重跑。\n'
  exit 1
fi
printf '已发布：全部（%s）\n' "$(IFS=,; echo "${published[*]}")"

say "完成"
# 只核对**已发布**的包：对没发出去的包 `npm view` 会给出旧版本，那会被误报成成功。
# `${published[@]+…}` 是空数组的安全写法：`set -u` 下直接展开空数组在旧 bash 里算未定义。
for name in ${published[@]+"${published[@]}"}; do
  pkg="$(node -p "require('$ROOT/plugins/$name/package.json').name")"
  printf '  %s → https://www.npmjs.com/package/%s\n' "$pkg" "$pkg"
done
cat <<'NOTE'

别忘了：插件包装上之后，`dsh plugin --profile web add <name>` 才是真正给用户的路。
建议立刻在一台干净的机器（或临时 DSH_HOME）上试一次安装，确认它能成为 profile 的一层。
NOTE
