#!/usr/bin/env bash
# codegraph 判级守卫：检测 code-review-graph 可用性并跑 detect-changes。
# 退出码: 0=已输出风险摘要; 3=不可用(应降级为人工判级)
# 用法: codegraph-judge.sh [--repo R] [--base B] assess
set -euo pipefail
REPO="$PWD"; BASE="HEAD~1"
while [ "${1:-}" ] && [ "${1#--}" != "$1" ]; do
  case "$1" in --repo) REPO="$2"; shift 2;; --base) BASE="$2"; shift 2;; *) break;; esac
done

if ! command -v code-review-graph >/dev/null 2>&1; then
  echo "ℹ codegraph 不可用（未安装 code-review-graph）→ 降级为纯人工判级" >&2; exit 3
fi
if [ ! -f "$REPO/.code-review-graph/graph.db" ]; then
  echo "ℹ codegraph 图未构建（缺 graph.db）→ 降级为纯人工判级；可运行 code-review-graph build" >&2; exit 3
fi

echo "=== codegraph 判级信号（base=$BASE）==="
code-review-graph detect-changes --brief --base "$BASE" --repo "$REPO" 2>&1
echo "--- 判级校准提示 ---"
echo "risk≥0.4 / 改动文件≥8 / 有 affected flow → 至少 L1；有 test gap 且改了已有函数 → 锁 L2/L3 必须补测试；risk≈0 且 0 changed → L4。冲突偏严。"
echo "若图风险与你判级明显背离，按一次「判级被数据纠正」记入：learnings.sh add 判级/图风险背离 <repo> \"<note>\""
