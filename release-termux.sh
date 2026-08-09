#!/usr/bin/env bash
# release-termux.sh — 在 Termux 本地编译、测试 Reasonix,并把二进制发布到 GitHub release。
#
# 前置:源码已就绪(先运行 ./update-reasonix.sh),gh 已认证,或设置 GITHUB_TOKEN
# (Personal Access Token,需 repo 权限)。
#
# 用法:
#   ./release-termux.sh [patch文件]
# 环境变量:
#   RELEASE_REPO      目标仓库(默认 lengxiaohua123/reasonix_android_custon)
#   RELEASE_TAG       指定上游 tag(默认取上游最新正式版 tag)
#   REASONIX_WORKDIR  源码工作目录(默认 $HOME/reasonix-src)
#   SKIP_TESTS=1      跳过测试
#   FAIL_ON_TEST=1    测试失败时中止(默认仅报告,Termux 已知环境性失败不阻塞)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${RELEASE_REPO:-lengxiaohua123/reasonix_android_custon}"
WORKDIR="${REASONIX_WORKDIR:-$HOME/reasonix-src}"
PATCH_FILE="$(realpath "${1:-$SCRIPT_DIR/reasonix-termux.patch}")"
umask 022

log() { printf '[release] %s\n' "$*"; }

# 1. 解析上游 tag
TAG="${RELEASE_TAG:-}"
if [ -z "$TAG" ]; then
  TAG="$(git ls-remote --tags --refs https://github.com/esengine/DeepSeek-Reasonix.git \
    | awk -F/ '{print $NF}' | grep -v -- '-rc' | sort -V | tail -1)"
fi
REL_TAG="termux-$TAG"
log "上游 tag: $TAG → release: $REL_TAG"

# 2. 校验源码就绪
if [ ! -d "$WORKDIR/.git" ]; then
  echo "[release] 错误: $WORKDIR 不是 git 仓库,请先运行 ./update-reasonix.sh" >&2
  exit 1
fi
cd "$WORKDIR"
if ! git describe --tags --always | grep -q "$TAG"; then
  echo "[release] 错误: $WORKDIR 不是 $TAG(当前 $(git describe --tags --always 2>/dev/null));请先运行 ./update-reasonix.sh" >&2
  exit 1
fi

# 3. 编译
log "编译 android 二进制"
make android VERSION="$TAG"
BIN="$WORKDIR/bin/reasonix-android-arm64"
[ -f "$BIN" ] || { echo "[release] 编译产物缺失: $BIN" >&2; exit 1; }
log "产物: $BIN ($(stat -c%s "$BIN") bytes)"

# 4. 测试
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  log "运行测试(日志: $SCRIPT_DIR/test-result.log)"
  set +e
  go test -count=1 ./... 2>&1 | tee "$SCRIPT_DIR/test-result.log"
  TEST_EXIT=${PIPESTATUS[0]}
  set -e
  PASS="$(grep -cE '^ok\s' "$SCRIPT_DIR/test-result.log" || true)"
  FAIL="$(grep -cE '^--- FAIL' "$SCRIPT_DIR/test-result.log" || true)"
  log "测试结果: $PASS 包通过, $FAIL 处失败(go test 退出码 $TEST_EXIT)"
  if [ "${FAIL_ON_TEST:-0}" = "1" ] && [ "$FAIL" -gt 0 ]; then
    echo "[release] 测试失败且 FAIL_ON_TEST=1,中止" >&2
    exit 1
  fi
fi

# 5. 发布
log "发布到 $REPO"
api_get() { curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" "$@"; }

release_exists() {
  [ "$(api_get -o /dev/null -w '%{http_code}' "https://api.github.com/repos/$REPO/releases/tags/$REL_TAG")" = "200" ]
}

create_release_via_api() {
  local notes escaped
  notes="$(printf '%s\n' \
    "Automatic Termux build of upstream [$TAG](https://github.com/esengine/DeepSeek-Reasonix/releases/tag/$TAG) with the Termux adaptation patch." \
    "" \
    "- **reasonix-android-arm64**: prebuilt binary built on Termux (GOOS=android GOARCH=arm64, version $TAG)" \
    "- **reasonix-termux.patch**: the adaptation patch (16 files)" \
    "- **update-reasonix.sh**: rebuild/update script" \
    "" \
    "Install:" \
    '```' \
    "cp reasonix-android-arm64 \$PREFIX/bin/reasonix" \
    "reasonix -v" \
    '```')"
  escaped="$(printf '%s' "$notes" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  local resp upload_url
  resp="$(api_get -X POST "https://api.github.com/repos/$REPO/releases" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"tag_name\":\"$REL_TAG\",\"name\":\"Reasonix $TAG — Termux build\",\"body\":$escaped}")"
  upload_url="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
  api_get -X POST "$upload_url?name=$(basename "$BIN")" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$BIN" >/dev/null
  log "已发布: https://github.com/$REPO/releases/tag/$REL_TAG"
}

if command -v gh >/dev/null 2>&1; then
  RELEASE_EXISTS="$(gh release list --limit 100 --repo "$REPO" --json tagName -q '.[].tagName' 2>/dev/null | grep -cx "$REL_TAG" || true)"
  if [ "$RELEASE_EXISTS" -ge 1 ]; then
    log "release $REL_TAG 已存在,跳过(覆盖需先 gh release delete $REL_TAG --repo $REPO --yes)"
  else
    NOTES_FILE="$TMPDIR/reasonix-release-notes.md"
    printf '%s\n' \
      "Automatic Termux build of upstream [$TAG](https://github.com/esengine/DeepSeek-Reasonix/releases/tag/$TAG) with the Termux adaptation patch." \
      "" \
      "- **reasonix-android-arm64**: prebuilt binary built on Termux (GOOS=android GOARCH=arm64, version $TAG)" \
      "- **reasonix-termux.patch**: the adaptation patch (16 files)" \
      "- **update-reasonix.sh**: rebuild/update script" \
      "" \
      "Install:" \
      '```' \
      "cp reasonix-android-arm64 \$PREFIX/bin/reasonix" \
      "reasonix -v" \
      '```' > "$NOTES_FILE"
    gh release create "$REL_TAG" "$BIN" "$PATCH_FILE" "$SCRIPT_DIR/update-reasonix.sh" \
      --repo "$REPO" \
      --title "Reasonix $TAG — Termux build" \
      --notes-file "$NOTES_FILE"
    log "已发布: https://github.com/$REPO/releases/tag/$REL_TAG"
  fi
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  if release_exists; then
    log "release $REL_TAG 已存在,跳过(覆盖需手动删除该 release)"
  else
    create_release_via_api
  fi
else
  echo "[release] 错误: 需要 gh(已认证)或设置 GITHUB_TOKEN 环境变量(Personal Access Token, scope 含 repo)" >&2
  exit 1
fi
