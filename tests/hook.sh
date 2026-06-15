#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
H="$HERE/scripts/detect-judging-correction.py"
T="$(mktemp)"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"级别 = L3｜理由 = bug"}]}}' > "$T"

out="$(echo "{\"prompt\":\"不对，应该是 L2\",\"transcript_path\":\"$T\"}" | "$H")"
echo "$out" | grep -q "进化检测" || { echo "FAIL: 正例应注入"; exit 1; }
out2="$(echo "{\"prompt\":\"帮我加个按钮\",\"transcript_path\":\"$T\"}" | "$H")"
[ -z "$out2" ] || { echo "FAIL: 反例应静默"; exit 1; }
echo "PASS tests/hook.sh"
