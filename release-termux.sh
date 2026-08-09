#!/usr/bin/env bash
# release-termux.sh — 在 Termux 本地编译、测试 Reasonix,并把编译好的二进制
# 上传到本仓库 artifacts/(GitHub Action verify-and-release.yml 校验版本与
# 上游最新 tag 一致后自动创建 release)。
#
# 前置:源码已就绪(先运行 ./update-reasonix.sh),本仓库可 push(SSH key)。
#
# 用法:
#   ./release-termux.sh [patch文件]
# 环境变量:
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
    | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.' | grep -v -- '-rc' | sort -V | tail -1)"
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
  # 全量并行下 Termux 资源有限,已知测试会偶发超时/排序 flaky;
  # 对失败包单独重跑一次,仍失败才算真失败。
  if [ "$TEST_EXIT" -ne 0 ]; then
    FAIL_PKGS="$(grep -E '^FAIL\s' "$SCRIPT_DIR/test-result.log" | awk '{print $2}' | sort -u)"
    RETEST_OK=1
    for p in $FAIL_PKGS; do
      if go test -count=1 "$p" >/dev/null 2>&1; then
        log "重跑通过(并发 flaky): $p"
      else
        log "重跑仍失败: $p"
        RETEST_OK=0
      fi
    done
    if [ "$RETEST_OK" = "1" ]; then
      log "所有失败均为并发 flaky,单独重跑全部通过"
      TEST_EXIT=0
    fi
  fi
  PASS="$(grep -cE '^ok\s' "$SCRIPT_DIR/test-result.log" || true)"
  FAIL="$(grep -cE '^--- FAIL' "$SCRIPT_DIR/test-result.log" || true)"
  log "测试结果: $PASS 包通过, $FAIL 处失败(go test 退出码 $TEST_EXIT)"
  if [ "${FAIL_ON_TEST:-0}" = "1" ] && [ "$TEST_EXIT" -ne 0 ]; then
    echo "[release] 测试失败且 FAIL_ON_TEST=1,中止" >&2
    exit 1
  fi
fi

# 5. 上传二进制到仓库(发布由 GitHub Action 校验版本/hash 后完成)
log "上传二进制到仓库 artifacts/"
ART_DIR="$SCRIPT_DIR/artifacts"
mkdir -p "$ART_DIR"
cp "$BIN" "$ART_DIR/reasonix-android-arm64"
cd "$SCRIPT_DIR"
git add artifacts/reasonix-android-arm64
if git commit -m "upload reasonix-android-arm64 $TAG" >/dev/null 2>&1; then
  git push origin master
  log "已上传 $TAG 二进制,等待 Action 校验并发布: https://github.com/$REPO/actions"
else
  log "二进制内容无变化,无需重新上传(最近提交: $(git log -1 --format=%s))"
fi
