#!/usr/bin/env bash
# 数学教练换新版：只在用户明确同意后由教练自己调用，替他把文件换掉。
#
# 用法（成人回了 1、表示同意换新版之后）：
#   bash "<本 SKILL.md 所在目录>/scripts/update-skill.sh"
#
# 它做四件事：
#   1. 读公开仓库的 UPDATE.json，确认远端版本真的比本地新；
#   2. 按 UPDATE.json 里的文件清单逐个下载（jsdelivr → GitHub API → 官方 raw，三路兜底），
#      除主文件外每个文件都核 md5，主文件核版本号与 name；
#   3. 先把整个旧目录备份到 ~/.nuan-math-coach/backup-<旧版本>-<时间>/，再覆盖写入；
#   4. 写完回读校验，任何一步出错就把备份盖回去，保持原样。
#
# 三条边界：
#   - 不碰用户自己的工作目录，孩子档案与内部日志在别处，一个字节都不动；
#   - 不删任何本地多出来的文件，只覆盖清单里的那几个；
#   - 装在写不进去的位置（平台托管）就直接如实报失败，不硬来。

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SELF_DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "这台机器上没有 python3，换不了。请自己去 GitHub 搜 nuan-math-coach，下载最新那个包解开覆盖旧文件夹。"
  exit 0
fi

python3 - "$SKILL_DIR" <<'PY'
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = "ahnuange/nuan-math-coach"
SKILL_DIR = os.path.abspath(sys.argv[1])
STATE_DIR = os.path.join(os.path.expanduser("~"), ".nuan-math-coach")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
NAME_RE = re.compile(r"^name:\s*nuan-math-coach\s*$", re.M)

# 清单里这几份允许本地缺失（不同市场包里带的不一样）
OPTIONAL_FILES = {"LICENSE", "README.md"}


def say(msg):
    print(msg)
    sys.exit(0)


def fetch(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "nuan-math-coach-updater"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def read_local_version():
    path = os.path.join(SKILL_DIR, "SKILL.md")
    try:
        with open(path, encoding="utf-8") as f:
            head = f.read(4000)
    except OSError:
        return None
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", head, re.M)
    return m.group(1) if m else None


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def load_manifest():
    sources = [
        "https://cdn.jsdelivr.net/gh/%s@main/UPDATE.json" % REPO,
        "https://api.github.com/repos/%s/contents/UPDATE.json?ref=main" % REPO,
        "https://raw.githubusercontent.com/%s/main/UPDATE.json" % REPO,
    ]
    for url in sources:
        try:
            raw = fetch(url, 8)
        except Exception:
            continue
        try:
            text = raw.decode("utf-8")
            if url.startswith("https://api.github.com"):
                import base64
                text = base64.b64decode(json.loads(text)["content"]).decode("utf-8")
            data = json.loads(text)
            version = data["version"]
            files = data["files"]
            if not VERSION_RE.match(version):
                continue
            if not isinstance(files, dict) or not files:
                continue
            if any(not isinstance(k, str) or not isinstance(v, str) for k, v in files.items()):
                continue
            if any(".." in k or k.startswith("/") for k in files):
                continue
            return version, files, data.get("notice", "")
        except Exception:
            continue
    return None


def file_sources(rel, version):
    return [
        "https://cdn.jsdelivr.net/gh/%s@v%s/%s" % (REPO, version, rel),
        "https://api.github.com/repos/%s/contents/%s?ref=v%s" % (REPO, rel, version),
        "https://raw.githubusercontent.com/%s/v%s/%s" % (REPO, version, rel),
    ]


def download(rel, version):
    for url in file_sources(rel, version):
        try:
            raw = fetch(url, 10)
        except Exception:
            continue
        if url.startswith("https://api.github.com"):
            try:
                import base64
                raw = base64.b64decode(json.loads(raw.decode("utf-8"))["content"])
            except Exception:
                continue
        if raw:
            return raw
    return None


def split_frontmatter(text):
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return None, text
    return text[4:end], text[end + 5:]


def keep_local_extras(local_text, new_text):
    """市场包里多出来的 frontmatter 字段（如 display_name）保留下来，别一换就丢。"""
    local_fm, _ = split_frontmatter(local_text)
    new_fm, new_body = split_frontmatter(new_text)
    if local_fm is None or new_fm is None:
        return new_text
    new_keys = set()
    for line in new_fm.splitlines():
        if ":" in line and not line.startswith((" ", "\t", "-")):
            new_keys.add(line.split(":", 1)[0].strip())
    extras = []
    for line in local_fm.splitlines():
        if ":" in line and not line.startswith((" ", "\t", "-")):
            if line.split(":", 1)[0].strip() not in new_keys:
                extras.append(line)
    if not extras:
        return new_text
    return "---\n" + new_fm + "\n" + "\n".join(extras) + "\n---\n" + new_body


def main():
    local_version = read_local_version()
    if not local_version:
        say("读不到本地版本号，没敢动。请自己去 GitHub 搜 nuan-math-coach，下载最新那个包解开覆盖旧文件夹。")

    manifest = load_manifest()
    if not manifest:
        say("连不上更新信息，这次没换。等会儿有网了再说一句「更新数学教练」就行。")
    remote_version, files, _notice = manifest

    if vtuple(remote_version) <= vtuple(local_version):
        say("你手上这份已经是最新的 v%s 了，不用换。" % local_version)

    files = dict(files)
    for name in list(files):
        if name in OPTIONAL_FILES and not os.path.exists(os.path.join(SKILL_DIR, name)):
            files.pop(name)

    tmp = tempfile.mkdtemp(prefix="nmc-update-")
    staged = {}
    try:
        for rel, expect_md5 in files.items():
            raw = download(rel, remote_version)
            if raw is None:
                say("新版文件下不下来（%s），这次没换。等会儿有网了再说一句「更新数学教练」。" % rel)
            got = hashlib.md5(raw).hexdigest()
            if rel != "SKILL.md" and expect_md5 and got != expect_md5:
                say("下载到的文件对不上号（%s），为了安全没换。" % rel)
            staged[rel] = raw
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    new_skill = staged["SKILL.md"].decode("utf-8", errors="replace")
    if not NAME_RE.search(new_skill):
        say("下载到的不是数学教练的文件，没换。")
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", new_skill, re.M)
    if not m or vtuple(m.group(1)) != vtuple(remote_version):
        say("下载到的版本号对不上，没换。")

    try:
        with open(os.path.join(SKILL_DIR, "SKILL.md"), encoding="utf-8") as f:
            local_skill = f.read()
    except OSError:
        local_skill = ""
    staged["SKILL.md"] = keep_local_extras(local_skill, new_skill).encode("utf-8")

    os.makedirs(STATE_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = os.path.join(STATE_DIR, "backup-v%s-%s" % (local_version, stamp))
    try:
        shutil.copytree(SKILL_DIR, backup)
    except Exception as e:
        say("旧版本备份不了（%s），为了安全没换。" % type(e).__name__)

    written = []
    try:
        for rel, raw in staged.items():
            dest = os.path.join(SKILL_DIR, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(raw)
            written.append(rel)
        if read_local_version() != remote_version:
            raise RuntimeError("readback mismatch")
    except Exception:
        for rel in written:
            old = os.path.join(backup, rel)
            dest = os.path.join(SKILL_DIR, rel)
            try:
                if os.path.exists(old):
                    shutil.copy2(old, dest)
            except Exception:
                pass
        say("换到一半没成功，已经把旧的放回去了。请自己去 GitHub 搜 nuan-math-coach，下载最新那个包解开覆盖旧文件夹。")

    print("换好了，从 v%s 换到 v%s，一共 %d 个文件。" % (local_version, remote_version, len(staged)))
    print("旧的整份备份在 %s，不放心可以自己盖回去。" % backup)
    print("这个会话加载的还是旧规则，新开一次对话才算用上新的。")


main()
PY
