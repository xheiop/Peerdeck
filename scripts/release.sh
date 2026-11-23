#!/bin/zsh
# 发版：按提交生成 CHANGELOG.md 里新版本的那一节，提交、打 tag、推送。推送 tag 以后由 release workflow 构建和发布。
#
#   scripts/release.sh                 # 按提交算版本号：feat 升次版本号，fix / perf 升修订号
#   scripts/release.sh 0.3.0           # 指定版本号
#   scripts/release.sh 0.3.0-beta.1    # 预发布：发成 GitHub 预发布，不动 Homebrew 和 AltStore 源
#   scripts/release.sh --dry-run       # 只打印版本号和这一节，什么都不改
#   scripts/release.sh --no-edit       # 不打开编辑器润色
#
# 步骤：检查（在 main 上、工作区干净、没落后于 origin、tag 不存在）→ 用 git-cliff 生成这一节
#   → 用 $VISUAL / $EDITOR 打开润色 → 确认 → 写进 CHANGELOG.md（正式版顺便改 Info.plist 和 project.yml 里的默认版本号）
#   → 提交 `chore(release): vX.Y.Z`、打 tag，把 main 和 tag 一起推上去。
# [Unreleased] 下面手写的内容会放到新版本这一节的最前面，用来写提交信息里写不出来的提醒。
# CHANGELOG 里已经有手写的 `## [x.y.z] - Unreleased` 时不生成，只把 Unreleased 换成日期（0.1.0 就是这样）。
# 提交信息的约定写在 cliff.toml 开头。需要 git-cliff：brew install git-cliff
set -euo pipefail

die() { print -u2 -- "release: $*"; exit 1 }

ROOT=${0:A:h:h}
cd "$ROOT"
REMOTE=origin
BRANCH=main
PLIST=App/Sources/Peerdeck/Resources/Info.plist
PROJECT=iOS/project.yml
RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

DRY=0 EDIT=1 VERSION=
for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    --no-edit) EDIT=0 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) die "不认识的参数：$arg" ;;
    *) [[ -z $VERSION ]] || die "只能给一个版本号"; VERSION=${arg#v} ;;
  esac
done

cliff() {
  command -v git-cliff >/dev/null || die "缺 git-cliff：brew install git-cliff"
  git-cliff --config cliff.toml "$@"
}

# a > b，都是 x.y.z
version_gt() {
  local -a a b
  a=(${(s:.:)1}) b=(${(s:.:)2})
  local i
  for i in 1 2 3; do
    (( a[i] > b[i] )) && return 0
    (( a[i] < b[i] )) && return 1
  done
  return 1
}

# 改 CHANGELOG 和默认版本号的部分
PY=$(cat <<'EOF'
import re, sys

UNRELEASED = "## [Unreleased]"
LINK = re.compile(r"^\[[^\]]+\]: ")

def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def tidy(text):
    return re.sub(r"\n{3,}", "\n\n", text.strip())

def unreleased_bounds(lines):
    if UNRELEASED not in lines:
        sys.exit(f"CHANGELOG.md 里没有 {UNRELEASED} 这一行")
    i = lines.index(UNRELEASED)
    j = i + 1
    while j < len(lines) and not lines[j].startswith("## [") and not LINK.match(lines[j]):
        j += 1
    return i, j

def sub_once(pattern, repl, text, what, flags=0):
    text, n = re.subn(pattern, repl, text, flags=flags)
    if n != 1:
        sys.exit(f"没找到 {what}")
    return text

cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "unreleased":
    lines = read(args[0]).split("\n")
    i, j = unreleased_bounds(lines)
    print(tidy("\n".join(lines[i + 1 : j])))
elif cmd == "join":
    parts = [tidy(read(p)) for p in args]
    print("\n\n".join(p for p in parts if p))
elif cmd == "apply":
    path, version, date, notes_path, last, mode = args
    lines = read(path).split("\n")
    if mode == "hand":
        heading = f"## [{version}] - Unreleased"
        lines[lines.index(heading)] = f"## [{version}] - {date}"
    else:
        i, j = unreleased_bounds(lines)
        notes = tidy(read(notes_path)).split("\n")
        lines = lines[: i + 1] + ["", f"## [{version}] - {date}", "", *notes, ""] + lines[j:]
    tag = f"v{version}"
    target = f"../../compare/{last}...{tag}" if last else f"../../releases/tag/{tag}"
    links = [k for k, line in enumerate(lines) if line.startswith("[Unreleased]: ")]
    if links:
        lines[links[0]] = f"[Unreleased]: ../../compare/{tag}...HEAD"
        if not any(line.startswith(f"[{version}]: ") for line in lines):
            lines.insert(links[0] + 1, f"[{version}]: {target}")
    else:
        while lines and not lines[-1]:
            lines.pop()
        lines += ["", f"[Unreleased]: ../../compare/{tag}...HEAD", f"[{version}]: {target}", ""]
    write(path, "\n".join(lines))
elif cmd == "bump":
    version, plist, project = args
    write(plist, sub_once(r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)",
                          rf"\g<1>{version}\g<2>", read(plist), f"{plist} 里的 CFBundleShortVersionString"))
    write(project, sub_once(r'^(\s*MARKETING_VERSION:\s*)"[^"]*"', rf'\g<1>"{version}"', read(project),
                            f"{project} 里的 MARKETING_VERSION", re.M))
else:
    sys.exit(f"unknown command {cmd}")
EOF
)
py() { python3 -c "$PY" "$@" }

# ---- 检查 ----
if (( ! DRY )); then
  [[ $(git symbolic-ref --short -q HEAD) == $BRANCH ]] || die "要在 $BRANCH 分支上发版"
  [[ -z $(git status --porcelain) ]] || die "工作区有没提交的改动"
fi
git fetch --quiet --tags $REMOTE $BRANCH
if (( ! DRY )); then
  git merge-base --is-ancestor $REMOTE/$BRANCH HEAD || die "本地 $BRANCH 落后于 $REMOTE/$BRANCH，先 git pull"
fi

LAST=$(git tag --list 'v[0-9]*' --merged HEAD --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
HAND=$(sed -nE 's/^## \[([^]]+)\] - Unreleased$/\1/p' CHANGELOG.md | head -1)

if [[ -z $VERSION ]]; then
  if [[ -n $HAND ]]; then
    VERSION=$HAND
  else
    VERSION=$(cliff --bumped-version) || die "git-cliff 算不出版本号"
    VERSION=${VERSION#v}
    [[ v$VERSION != $LAST ]] || die "$LAST 以后没有 feat / fix / perf 提交，没什么可发的"
  fi
fi
[[ $VERSION =~ $RE ]] || die "版本号格式不对：$VERSION（要 x.y.z 或 x.y.z-后缀）"
[[ -z $HAND || $HAND == $VERSION ]] || die "CHANGELOG 里有手写的 [$HAND] - Unreleased，和要发的 $VERSION 对不上"
TAG=v$VERSION
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG 已经存在"
if [[ -n $LAST ]] && ! version_gt ${VERSION%%-*} ${LAST#v}; then
  die "$VERSION 要大于上一个正式版 ${LAST#v}"
fi
PRERELEASE=0
[[ $VERSION == *-* ]] && PRERELEASE=1

# ---- 这一节的说明 ----
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [[ $VERSION == $HAND ]]; then
  MODE=hand
  scripts/release-notes.sh "$VERSION" > "$TMP/notes.md"
else
  MODE=gen
  py unreleased CHANGELOG.md > "$TMP/unreleased.md"
  cliff --unreleased --tag "$TAG" --strip all > "$TMP/generated.md" || die "git-cliff 生成失败"
  py join "$TMP/unreleased.md" "$TMP/generated.md" > "$TMP/notes.md"
fi
[[ -n ${$(<"$TMP/notes.md")//[[:space:]]/} ]] ||
  die "上一个正式版以后没有要写进 changelog 的内容（只有 feat / fix / perf 会写进去）。可以在 [Unreleased] 下面手写说明"

if (( DRY )); then
  print -- "版本：$TAG（上一个正式版：${LAST:-无}）"
  (( PRERELEASE )) && print -- "预发布：不更新 Homebrew 和 AltStore 源"
  print -- "\n## [$VERSION] - $(date +%F)\n"
  cat "$TMP/notes.md"
  exit 0
fi

if (( EDIT )) && [[ $MODE == gen ]]; then
  ${=${VISUAL:-${EDITOR:-vi}}} "$TMP/notes.md"
  [[ -n ${$(<"$TMP/notes.md")//[[:space:]]/} ]] || die "这一节是空的，已取消，什么都没改"
fi

print -- "\n要发布 $TAG（上一个正式版：${LAST:-无}）$( (( PRERELEASE )) && print -- '，预发布' )。说明：\n"
cat "$TMP/notes.md"
print
REPLY=
read -r "REPLY?写进 CHANGELOG.md、提交、打 tag 并推送到 $REMOTE？[y/N] " || true
[[ $REPLY == [yY]* ]] || die "已取消，什么都没改"

# ---- 写入、提交、推送 ----
py apply CHANGELOG.md "$VERSION" "$(date +%F)" "$TMP/notes.md" "$LAST" "$MODE"
FILES=(CHANGELOG.md)
if (( ! PRERELEASE )); then
  py bump "$VERSION" "$PLIST" "$PROJECT"
  FILES+=("$PLIST" "$PROJECT")
fi
git add -- $FILES
git commit -q -m "chore(release): $TAG"
git tag -a "$TAG" -m "$TAG"
git push --atomic --quiet $REMOTE $BRANCH "$TAG" ||
  die "推送失败。本地已经有提交和 tag，修好以后运行：git push --atomic $REMOTE $BRANCH $TAG"

print -- "\n已推送 $TAG。Release workflow 会测试、构建并发布，进度在 GitHub 的 Actions 页面。"
(( PRERELEASE )) || print -- "发布完成后 workflow 会往 $BRANCH 提交 Casks/peerdeck.rb，到时候 git pull 拿回来。"
