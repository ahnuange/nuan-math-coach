#!/usr/bin/env bash
# 数学教练版本检查：24 小时内最多联网一次，有新版本时只输出一行给大人看的话。
#
# 用法（由 SKILL.md 在整轮收口之后调用，正课中途不调）：
#   bash "<本 SKILL.md 所在目录>/scripts/check-update.sh"
#
# 设计三条硬规矩：
#   1. 全程静默失败。没网、没权限、远端格式不对、本地版本读不到，一律 exit 0 且不输出，
#      绝不让一次版本检查打断孩子的对话，也绝不编一句「已是最新版」。
#   2. 24 小时只联网一次，缓存写在 ~/.nuan-math-coach/update_check_at。
#   3. 只在远端版本严格高于本地时才输出，最多一行。

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_MD="$SELF_DIR/../SKILL.md"
STATE_DIR="${NUAN_UPDATE_CACHE_DIR:-$HOME/.nuan-math-coach}"
CACHE_FILE="$STATE_DIR/update_check_at"
CACHE_TTL=86400

# 国内直连 raw.githubusercontent.com 常被挡，先试 jsdelivr 镜像（慢一点但通），再试官方 raw
# jsdelivr 实测 2.4 到 4.7 秒都有，卡 8 秒；raw 直连经常整个超时，只给 4 秒
URLS=(
  "${NUAN_UPDATE_URL:-https://cdn.jsdelivr.net/gh/ahnuange/nuan-math-coach@main/UPDATE.json}|8"
  "https://raw.githubusercontent.com/ahnuange/nuan-math-coach/main/UPDATE.json|4"
)

IGNORE_CACHE=0
[ "${1:-}" = "--ignore-cache" ] && IGNORE_CACHE=1

# 本地版本从 SKILL.md 的 frontmatter 读，不手写常量，免得改了版本忘了同步这一处
LOCAL_VERSION=""
if [ -f "$SKILL_MD" ]; then
  RAW_VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$SKILL_MD" 2>/dev/null | head -1)"
  RAW_VERSION="${RAW_VERSION//\"/}"
  RAW_VERSION="${RAW_VERSION//\'/}"
  LOCAL_VERSION="$(printf '%s' "$RAW_VERSION" | tr -d '[:space:]')"
fi
if [[ ! "$LOCAL_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  exit 0
fi

NOW="$(date +%s)"
if [ "$IGNORE_CACHE" = "0" ] && [ -f "$CACHE_FILE" ]; then
  LAST_CHECK="$(tr -d '[:space:]' < "$CACHE_FILE" 2>/dev/null || true)"
  if [[ "$LAST_CHECK" =~ ^[0-9]+$ ]] && [ "$NOW" -ge "$LAST_CHECK" ] && [ $((NOW - LAST_CHECK)) -lt "$CACHE_TTL" ]; then
    exit 0
  fi
fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
printf '%s\n' "$NOW" > "$CACHE_FILE" 2>/dev/null || true

PAYLOAD=""
for entry in "${URLS[@]}"; do
  case "$entry" in
    *"|"*) url="${entry%|*}"; secs="${entry##*|}" ;;
    *) url="$entry"; secs=8 ;;
  esac
  [ -n "$url" ] || continue
  case "$secs" in ''|*[!0-9]*) secs=8 ;; esac
  PAYLOAD="$(curl -fsS --max-time "$secs" "$url" 2>/dev/null || true)"
  [ -n "$PAYLOAD" ] && break
done
[ -n "$PAYLOAD" ] || exit 0

parse_with_python() {
  python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
    version = data.get("version", "")
    notice = data.get("notice", "")
    if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError
    if not isinstance(notice, str) or not 1 <= len(notice.strip()) <= 60 or any(ch in notice for ch in "\r\n\t"):
        raise ValueError
    print(f"{version}\t{notice.strip()}", end="")
except Exception:
    sys.exit(1)
'
}

parse_with_node() {
  node -e '
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => raw += chunk);
process.stdin.on("end", () => {
  try {
    const data = JSON.parse(raw);
    const version = data.version;
    const notice = data.notice;
    if (typeof version !== "string" || !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version)) process.exit(1);
    if (typeof notice !== "string" || notice.trim().length < 1 || notice.trim().length > 60 || /[\r\n\t]/.test(notice)) process.exit(1);
    process.stdout.write(`${version}\t${notice.trim()}`);
  } catch (_) {
    process.exit(1);
  }
});
'
}

if command -v python3 >/dev/null 2>&1; then
  PARSED="$(printf '%s' "$PAYLOAD" | parse_with_python 2>/dev/null || true)"
elif command -v node >/dev/null 2>&1; then
  PARSED="$(printf '%s' "$PAYLOAD" | parse_with_node 2>/dev/null || true)"
else
  exit 0
fi

[[ "$PARSED" == *$'\t'* ]] || exit 0
REMOTE_VERSION="${PARSED%%$'\t'*}"
NOTICE="${PARSED#*$'\t'}"

# notice 收尾统一成一句完整的话，拼起来才不别扭
case "$NOTICE" in
  *。|*！|*？) : ;;
  *) NOTICE="${NOTICE}。" ;;
esac

version_is_higher() {
  local remote_major remote_minor remote_patch local_major local_minor local_patch
  IFS=. read -r remote_major remote_minor remote_patch <<< "$1"
  IFS=. read -r local_major local_minor local_patch <<< "$2"
  if ((10#$remote_major != 10#$local_major)); then
    ((10#$remote_major > 10#$local_major))
  elif ((10#$remote_minor != 10#$local_minor)); then
    ((10#$remote_minor > 10#$local_minor))
  else
    ((10#$remote_patch > 10#$local_patch))
  fi
}

if version_is_higher "$REMOTE_VERSION" "$LOCAL_VERSION"; then
  printf '数学教练出新版了（v%s → v%s）。%s回一句 1，我现在帮你换。\n' \
    "$LOCAL_VERSION" "$REMOTE_VERSION" "$NOTICE"
fi
