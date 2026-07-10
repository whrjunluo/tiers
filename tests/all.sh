#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "=== 全量测试 ==="
for t in lib learnings workflow-state codegraph-judge external-agent doctor hook init install-codex install-cursor; do
  echo "--- $t ---"
  bash "$HERE/$t.sh"
done
echo "--- python hook unit ---"
python3 "$HERE/test_detect_judging_correction.py"
echo "--- evaluation schema unit ---"
python3 "$HERE/test_eval_schema.py"
echo "--- evaluation grader unit ---"
python3 "$HERE/test_eval_grade.py"
echo "=== 个人/工作区路径扫描 ==="
# 扫描发布文件里的本地泄露：① 绝对 home 路径（/Users/ /home/）；
# ② 非白名单的 ~/ 路径（只允许 ~/.claude、~/.codex、~/.cursor、~/.dev-workflow，挡住 ~/<工作区>/<项目> 这类泄露）。
# 字符类用 [A-Za-z0-9._-]，避免误伤 awk 的 `!~/regex/` 写法。
INC=(--include="*.sh" --include="*.md" --include="*.json" --include="*.py" --include="*.yml")
# 只扫会发布的文件：排除 .git、tests（含示例路径）、docs（内部设计稿，已 gitignore 不发布）
EXC=(--exclude-dir=.git --exclude-dir=tests --exclude-dir=docs)
abs=$(grep -rnE '/(Users|home)/[A-Za-z0-9._-]+/' "$HERE/.." "${INC[@]}" "${EXC[@]}" 2>/dev/null || true)
tilde=$(grep -rnE '~/[A-Za-z0-9._-]' "$HERE/.." "${INC[@]}" "${EXC[@]}" 2>/dev/null | grep -vE '~/\.(claude|codex|cursor|dev-workflow)' || true)
leaks=$(printf '%s\n%s\n' "$abs" "$tilde" | grep -v '^$' || true)
if [ -n "$leaks" ]; then
  echo "$leaks"
  echo "FAIL: 存在个人/工作区路径（仅允许 ~/.claude、~/.codex、~/.cursor、~/.dev-workflow）"; exit 1
else
  echo "✓ 无个人/工作区路径"
fi
echo "ALL PASS"
