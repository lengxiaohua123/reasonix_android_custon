#!/usr/bin/env bash
# update-reasonix.sh — 拉取 DeepSeek-Reasonix 最新 tag,应用 Termux 适配补丁,
# 编译 reasonix 并运行测试,测试日志写入文件。
#
# 用法:
#   ./update-reasonix.sh [patch文件] [日志文件]
# 环境变量:
#   REASONIX_REPO_URL   上游仓库(默认 https://github.com/esengine/DeepSeek-Reasonix.git)
#   REASONIX_TAG        指定 tag(默认取最新正式版 tag)
#   REASONIX_WORKDIR    源码工作目录(默认 $HOME/reasonix-src)
#   TEST_PKGS           go test 的包范围(默认 ./...)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="${REASONIX_REPO_URL:-https://github.com/esengine/DeepSeek-Reasonix.git}"
WORKDIR="${REASONIX_WORKDIR:-$HOME/reasonix-src}"
PATCH_FILE="$(realpath "${1:-$SCRIPT_DIR/reasonix-termux.patch}")"
LOG_FILE="$(realpath "${2:-reasonix-test-$(date +%Y%m%d-%H%M%S).log}")"
TEST_PKGS="${TEST_PKGS:-./...}"
umask 022

log() { printf '[update] %s\n' "$*"; }

# 1. 确定目标 tag:指定优先,否则取最新正式版(过滤 -rc 预发布)
if [ -z "${REASONIX_TAG:-}" ]; then
  TAG="$(git ls-remote --tags --refs "$REPO_URL" | awk -F/ '{print $NF}' | grep -v -- '-rc' | sort -V | tail -1)"
  [ -n "$TAG" ] || { echo "无法解析上游最新 tag" >&2; exit 1; }
  log "最新正式版 tag: $TAG"
else
  TAG="$REASONIX_TAG"
  log "指定 tag: $TAG"
fi

# 2. 拉取代码(首次 clone,之后 fetch + 检出)
if [ ! -d "$WORKDIR/.git" ]; then
  log "clone $TAG -> $WORKDIR"
  git clone --depth 1 --branch "$TAG" "$REPO_URL" "$WORKDIR"
else
  log "更新已有工作目录 $WORKDIR"
  # 本地 init 的仓库没有 origin 时补上,才能按 tag 更新。
  if ! git -C "$WORKDIR" remote get-url origin >/dev/null 2>&1; then
    git -C "$WORKDIR" remote add origin "$REPO_URL"
  fi
  log "警告: 将切换到 $TAG 的干净状态;本地未提交改动和当前分支历史会被丢弃(提交可经 git reflog 找回)"
  git -C "$WORKDIR" fetch --depth 1 origin tag "$TAG"
  git -C "$WORKDIR" checkout --force --detach "$TAG"
fi
git -C "$WORKDIR" reset --hard HEAD >/dev/null

# 3. 应用补丁
cd "$WORKDIR"
# 上次应用补丁留下的未跟踪新增文件会阻塞重新 apply;只清理补丁内 new file。
awk '/^diff --git /{p=$4; sub(/^b\//,"",p)} /^new file mode/{print p}' "$PATCH_FILE" | while read -r f; do
	rm -f "$f"
done
if ! git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "[update] 错误:补丁无法应用到 $TAG(上游相关文件可能已变化)" >&2
  echo "[update] 请检查 $PATCH_FILE 与上游 $TAG 的差异后手动合并" >&2
  exit 1
fi
git apply "$PATCH_FILE"
log "补丁应用成功($(grep -c '^diff --git' "$PATCH_FILE") 个文件)"

# 4. 编译 android 版 reasonix(复用 Makefile 的 android target)
# Version comes from the upstream tag explicitly; git describe is
# unreliable when a commit carries multiple tags (e.g. desktop-v1.21.3).
make android VERSION="$TAG"
log "编译完成: $WORKDIR/bin/reasonix-android-arm64 (version $TAG)"

# 5. 运行测试并写日志
log "运行测试: go test $TEST_PKGS"
log "测试日志: $LOG_FILE"
set +e
go test $TEST_PKGS 2>&1 | tee "$LOG_FILE"
TEST_EXIT="${PIPESTATUS[0]}"
set -e
FAILS="$(grep -cE '^--- FAIL|^FAIL\s' "$LOG_FILE" || true)"
PASS="$(grep -cE '^ok\s' "$LOG_FILE" || true)"
if [ "$FAILS" -gt 0 ] || [ "$TEST_EXIT" -ne 0 ]; then
  echo "[update] 结果: $PASS 个包通过, $FAILS 处失败,go test 退出码 $TEST_EXIT —— 详见 $LOG_FILE" >&2
  exit 2
fi
echo "[update] 结果: 全部通过($PASS 个包),日志: $LOG_FILE"
