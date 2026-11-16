#!/usr/bin/env bash
# 列出主仓库（upstream）自上次同步以来需要客户端跟进的改动，生成 .sync/pending.md 交给人或 AI 逐条处理。
#
#   scripts/sync-upstream.sh            拉取 upstream 的 dev，生成待同步清单（不移动子模块）
#   scripts/sync-upstream.sh --apply    清单处理完后，把子模块移到清单对应的提交并记入 SYNC.md
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH="${UPSTREAM_BRANCH:-dev}"
git -C upstream fetch -q origin "$BRANCH"
BASE=$(git rev-parse HEAD:upstream)
TARGET=$(git -C upstream rev-parse "origin/$BRANCH")
mkdir -p .sync

if [[ "${1:-}" == "--apply" ]]; then
  PENDING=$(sed -n 's/^目标提交：//p' .sync/pending.md 2>/dev/null | head -1)
  [[ -n "$PENDING" ]] || { echo "先运行一次不带参数的 sync-upstream.sh 生成清单" >&2; exit 1; }
  git -C upstream checkout -q "$PENDING"
  echo "| $(date +%F) | ${PENDING:0:9} | ${2:-已同步} |" >> SYNC.md
  git add upstream SYNC.md
  echo "子模块已移到 ${PENDING:0:9}，请检查后提交：git commit -m 'chore(sync): 对齐 upstream ${PENDING:0:9}'"
  exit 0
fi

if [[ "$BASE" == "$TARGET" ]]; then echo "已是最新（${BASE:0:9}），无需同步"; exit 0; fi

# 客户端关心的路径，按类别分组；其余改动（后台管理、迁移、部署等）不列出。
declare -A SYNC_PATHS=(
  ["样式 Token"]="apps/web/src/design-system"
  ["Web 页面与组件"]="apps/web/src/features apps/web/src/v3 apps/web/src/components apps/web/src/*.css"
  ["Web 接口客户端与类型"]="apps/web/src/api"
  ["简历纸面渲染（影响 apps/native/renderer）"]="apps/web/src/features/preview/print apps/web/public/templates contracts/resume"
  ["后端接口与权限"]="apps/backend/src/drawoffer/modules/*/routes.py apps/backend/src/drawoffer/modules/*/schemas.py apps/backend/src/drawoffer/api"
  ["接口契约文档"]="docs/api"
)

{
  echo "# 待同步清单"
  echo
  echo "上次同步：${BASE:0:9}"
  echo "目标提交：$TARGET"
  echo
  echo "## 期间合入的 PR"
  echo
  # 合并提交的正文首行是 PR 标题
  git -C upstream log --first-parent --merges --format='%h%x1f%s%x1f%b%x1e' "$BASE..$TARGET" \
    | awk -v RS='\x1e' -F'\x1f' 'NF>1 { sub(/^\n/, "", $1); split($3, body, "\n"); pr=$2; sub(/^Merge pull request /, "", pr); sub(/ from .*/, "", pr); print "- " $1 " " pr " " body[1] }'
  echo
  for name in "样式 Token" "Web 页面与组件" "Web 接口客户端与类型" "简历纸面渲染（影响 apps/native/renderer）" "后端接口与权限" "接口契约文档"; do
    # shellcheck disable=SC2086
    files=$(git -C upstream diff --stat=200 "$BASE..$TARGET" -- ${SYNC_PATHS[$name]} | sed '$d')
    [[ -z "$files" ]] && continue
    echo "## $name"
    echo
    echo '```'
    echo "$files"
    echo '```'
    echo
  done
  echo "## 处理方式"
  echo
  echo "逐条查看：git -C upstream log -p ${BASE:0:9}..${TARGET:0:9} -- <路径>。"
  echo "对每个 PR 判断 Mac（apps/mac）与 Windows（apps/windows）各要改什么；纯 Web 专属或后台管理的改动写明“不同步”及原因。"
  echo "全部处理完运行 scripts/sync-upstream.sh --apply \"一句话说明\"。"
} > .sync/pending.md

echo "已生成 .sync/pending.md（${BASE:0:9} → ${TARGET:0:9}）"
