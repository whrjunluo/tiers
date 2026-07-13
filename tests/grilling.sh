#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

GRILL_ME="$HERE/skills/grill-me/SKILL.md"
GRILLING="$HERE/skills/grilling/SKILL.md"

[ -f "$GRILL_ME" ] || { echo "FAIL: grill-me compatibility skill missing"; exit 1; }
[ -f "$GRILLING" ] || { echo "FAIL: grilling implementation skill missing"; exit 1; }

grep -q '^disable-model-invocation: true$' "$GRILL_ME" || { echo "FAIL: grill-me must remain explicit-only"; exit 1; }
grep -q 'Run a `/grilling` session\.' "$GRILL_ME" || { echo "FAIL: grill-me must delegate to grilling"; exit 1; }
grep -q '^name: grilling$' "$GRILLING" || { echo "FAIL: grilling frontmatter name missing"; exit 1; }
grep -q 'Ask the questions one at a time, waiting for feedback' "$GRILLING" || { echo "FAIL: grilling must wait after one question"; exit 1; }
grep -q 'If a \*fact\* can be found by exploring the environment' "$GRILLING" || { echo "FAIL: grilling must discover facts instead of asking"; exit 1; }
grep -q 'The \*decisions\*, though, are mine' "$GRILLING" || { echo "FAIL: grilling must leave decisions to the user"; exit 1; }
grep -q 'Do not act on it until I confirm' "$GRILLING" || { echo "FAIL: grilling must not implement before confirmation"; exit 1; }
grep -q 'skills/productivity/grilling' "$HERE/LICENSES/grill-me-MIT.txt" || { echo "FAIL: vendored license must cover grilling"; exit 1; }

python3 - "$GRILL_ME" "$GRILLING" <<'PY'
import difflib
import re
import sys
from pathlib import Path

expected = {
    "grill-me": """---
name: grill-me
description: A relentless interview to sharpen a plan or design.
disable-model-invocation: true
---

Run a `/grilling` session.
""",
    "grilling": """---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview me relentlessly about every aspect of this until we reach a shared understanding. Walk down each branch of the decision tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing. Asking multiple questions at once is bewildering.

If a *fact* can be found by exploring the environment (filesystem, tools, etc.), look it up rather than asking me. The *decisions*, though, are mine — put each one to me and wait for my answer.

Do not act on it until I confirm we have reached a shared understanding.
""",
}

for name, path_arg in zip(("grill-me", "grilling"), sys.argv[1:]):
    actual = Path(path_arg).read_text(encoding="utf-8")
    actual = re.sub(
        r"<!-- Vendored from mattpocock/skills@[^\n]+ -->\n\n",
        "",
        actual,
        count=1,
    )
    if actual != expected[name]:
        diff = "".join(
            difflib.unified_diff(
                expected[name].splitlines(keepends=True),
                actual.splitlines(keepends=True),
                fromfile=f"upstream/{name}",
                tofile=f"skills/{name}/SKILL.md",
            )
        )
        raise SystemExit(f"FAIL: {name} differs from vendored upstream text\n{diff}")
PY

echo "PASS tests/grilling.sh"
