# dev-workflow Plugin 化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把个人全局 skill `dev-workflow` 重构为可发布到 GitHub 的 Claude Code Plugin，零绝对路径、hook 自带、用户数据与代码分离，并内置 codegraph 判级集成（三层降级）。

**Architecture:** 新建独立 git 仓库 `~/gst-workspace/dev-workflow-plugin`。代码/模板随插件走（`${CLAUDE_PLUGIN_ROOT}`），用户积累数据放插件外数据区（`${DEV_WORKFLOW_DATA:-$HOME/.claude/dev-workflow}`）。状态由 shell 脚本独占读写（学 Comet 的 comet-state.sh），SKILL.md 只调脚本不手改文件。codegraph 通过 `detect-changes` guard 脚本接入并优雅降级。

**Tech Stack:** Bash + awk（脚本）、Python3（hook）、JSON（plugin 清单）、Markdown（skill/模板）。测试用 bash 断言脚本。

**仓库根：** `~/gst-workspace/dev-workflow-plugin/`（下文路径均相对于此，除非注明）。

**参考源（现有可复用实现）：**
- `~/.claude/skills/dev-workflow/SKILL.md`（决策树/判级/续行/进化全文）
- `~/.claude/skills/dev-workflow/learnings.sh`、`LEARNINGS.md`、`detect-judging-correction.py`（已测试通过）

---

## File Structure

| 文件 | 职责 |
|---|---|
| `.claude-plugin/plugin.json` | 插件清单：元信息 + UserPromptSubmit hook 声明 |
| `skills/dev-workflow/SKILL.md` | 工作流路由全文（路径改 `${CLAUDE_PLUGIN_ROOT}`，新增 codegraph 段，续行改调脚本） |
| `scripts/lib.sh` | 公共函数：解析数据区路径、首次从模板初始化 |
| `scripts/learnings.sh` | 进化日志独占接口（count/ready/categories/add/list） |
| `scripts/workflow-state.sh` | 续行状态独占接口（init/get/set/check） |
| `scripts/codegraph-judge.sh` | detect-changes 判级守卫 + 三层降级探测 |
| `scripts/detect-judging-correction.py` | UserPromptSubmit hook |
| `templates/LEARNINGS.md` | 进化日志模板（含 category 词表） |
| `templates/workflow-state.yaml` | 续行状态模板 |
| `bin/init` | 安装器（建数据区 + 检测引导依赖与 codegraph + gitignore） |
| `tests/*.sh` | 各脚本 bash 断言测试 |
| `README.md` / `LICENSE` / `.gitignore` | 发布元信息 |

---

## Task 1: 仓库骨架 + plugin 清单

**Files:**
- Create: `~/gst-workspace/dev-workflow-plugin/.gitignore`
- Create: `.claude-plugin/plugin.json`
- Create: `README.md`、`LICENSE`（MIT）

- [ ] **Step 1: 建仓库与目录**

```bash
mkdir -p ~/gst-workspace/dev-workflow-plugin/{.claude-plugin,skills/dev-workflow,scripts,templates,bin,tests}
cd ~/gst-workspace/dev-workflow-plugin && git init
```

- [ ] **Step 2: 写 .gitignore**

```
# 本地测试沙箱
/tmp-test-home/
*.log
.DS_Store
```

- [ ] **Step 3: 写 plugin.json（hook 暂留空，Task 7 填）**

```json
{
  "name": "dev-workflow",
  "version": "0.1.0",
  "description": "分级开发工作流路由（L0–L4）：判级加固、跨 session 续行、跨项目自主进化、codegraph 判级集成。",
  "author": "elvis",
  "license": "MIT"
}
```

- [ ] **Step 4: 写 README.md 骨架**

包含：简介、安装（`bin/init`）、三层 codegraph 降级说明、用户数据区位置、依赖（bash/awk/python3/git，可选 code-review-graph）。先写占位小节标题 + 一句话，详细内容 Task 9 回填。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "chore: 初始化 dev-workflow plugin 骨架"
```

---

## Task 2: 公共库 scripts/lib.sh（数据区解析 + 模板初始化）

**Files:**
- Create: `scripts/lib.sh`
- Test: `tests/lib.sh`

- [ ] **Step 1: 写失败测试 tests/lib.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export DEV_WORKFLOW_DATA="$(mktemp -d)/data"
source "$HERE/scripts/lib.sh"

# data_dir 应返回 DEV_WORKFLOW_DATA 并创建目录
d="$(dw_data_dir)"
[ "$d" = "$DEV_WORKFLOW_DATA" ] || { echo "FAIL: data_dir 路径不符"; exit 1; }
[ -d "$d" ] || { echo "FAIL: data_dir 未创建"; exit 1; }

# 首次应从模板复制 LEARNINGS.md
dw_ensure_learnings
[ -f "$d/LEARNINGS.md" ] || { echo "FAIL: LEARNINGS.md 未初始化"; exit 1; }
grep -q "category 词表" "$d/LEARNINGS.md" || { echo "FAIL: 模板内容缺失"; exit 1; }
echo "PASS tests/lib.sh"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/lib.sh`
Expected: FAIL（lib.sh 不存在 / 函数未定义）

- [ ] **Step 3: 写 scripts/lib.sh**

```bash
#!/usr/bin/env bash
# 公共函数：数据区解析与模板初始化。被其他脚本 source。
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

dw_data_dir() {
  local d="${DEV_WORKFLOW_DATA:-$HOME/.claude/dev-workflow}"
  mkdir -p "$d"
  printf '%s' "$d"
}

dw_ensure_learnings() {
  local d; d="$(dw_data_dir)"
  [ -f "$d/LEARNINGS.md" ] || cp "$PLUGIN_ROOT/templates/LEARNINGS.md" "$d/LEARNINGS.md"
}
```

- [ ] **Step 4: 临时建最小模板让测试可跑**

```bash
mkdir -p templates
printf '# dev-workflow 进化日志\n\n## category 词表\n```\n判级/行为守卫 守卫\n```\n## 进化记录\n<!-- 暂无记录 -->\n' > templates/LEARNINGS.md
```
（完整模板在 Task 4 替换）

- [ ] **Step 5: 运行确认通过**

Run: `bash tests/lib.sh`
Expected: `PASS tests/lib.sh`

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat: 公共库 lib.sh —— 数据区解析与模板初始化"
```

---

## Task 3: scripts/learnings.sh（移植 + 指向数据区）

**Files:**
- Create: `scripts/learnings.sh`（基于参考源，仅改 LEARNINGS 路径解析）
- Test: `tests/learnings.sh`

- [ ] **Step 1: 写失败测试 tests/learnings.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export DEV_WORKFLOW_DATA="$(mktemp -d)/data"
LS="$HERE/scripts/learnings.sh"

[ "$(bash "$LS" count)" = "（无 pending 记录）" ] || { echo "FAIL: 初始应为空"; exit 1; }
bash "$LS" add "判级/行为守卫" "repoA" "n1" >/dev/null
bash "$LS" add "判级/行为守卫" "repoB" "n2" >/dev/null
bash "$LS" ready | grep -q "判级/行为守卫" || { echo "FAIL: ≥2 应进 ready"; exit 1; }
bash "$LS" add "瞎写类" "x" "y" 2>/dev/null && { echo "FAIL: 非法 category 应拒绝"; exit 1; } || true
echo "PASS tests/learnings.sh"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/learnings.sh`
Expected: FAIL（learnings.sh 不存在）

- [ ] **Step 3: 写 scripts/learnings.sh**

复制参考源 `~/.claude/skills/dev-workflow/learnings.sh` 全文，仅将顶部路径解析替换为：

```bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
dw_ensure_learnings
LEARNINGS="$(dw_data_dir)/LEARNINGS.md"
```
（删除原来的 `LEARNINGS="$(cd "$(dirname "$0")"...)/LEARNINGS.md"` 那行；其余 `valid_cats/count/case` 逻辑原样保留。）

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/learnings.sh`
Expected: `PASS tests/learnings.sh`

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat: 移植 learnings.sh 至数据区路径"
```

---

## Task 4: 完整 LEARNINGS 模板（含新 category）

**Files:**
- Modify: `templates/LEARNINGS.md`（替换 Task 2 的占位）

- [ ] **Step 1: 写完整模板**

复制参考源 `~/.claude/skills/dev-workflow/LEARNINGS.md` 全文，并在 category 词表追加一行（spec「自主进化打通 codegraph」要求）：

```
判级/图风险背离   codegraph 风险分与我判级明显不符
```

- [ ] **Step 2: 回归测试**

Run: `bash tests/lib.sh && bash tests/learnings.sh`
Expected: 两个 PASS

- [ ] **Step 3: 提交**

```bash
git add -A && git commit -m "feat: 完整 LEARNINGS 模板并新增 判级/图风险背离 category"
```

---

## Task 5: scripts/workflow-state.sh（续行状态独占接口）

**Files:**
- Create: `scripts/workflow-state.sh`
- Create: `templates/workflow-state.yaml`
- Test: `tests/workflow-state.sh`

状态文件 per-project，路径：`<repo>/docs/superpowers/.workflow-state.yaml`（由 `--repo` 或 `$PWD` 决定）。

- [ ] **Step 1: 写模板 templates/workflow-state.yaml**

```yaml
task: ""
level: ""
phase: ""        # brainstorm | spec | plan | tdd | review | done
artifacts:
  spec: ""
  plan: ""
updated: ""
next: ""
```

- [ ] **Step 2: 写失败测试 tests/workflow-state.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WS="$HERE/scripts/workflow-state.sh"
REPO="$(mktemp -d)"

bash "$WS" --repo "$REPO" init
f="$REPO/docs/superpowers/.workflow-state.yaml"
[ -f "$f" ] || { echo "FAIL: 未初始化状态文件"; exit 1; }

bash "$WS" --repo "$REPO" set phase spec
[ "$(bash "$WS" --repo "$REPO" get phase)" = "spec" ] || { echo "FAIL: set/get phase"; exit 1; }

# check：非法 phase 应报错
bash "$WS" --repo "$REPO" set phase 乱写 2>/dev/null && { echo "FAIL: 非法 phase 应拒绝"; exit 1; } || true
echo "PASS tests/workflow-state.sh"
```

- [ ] **Step 3: 运行确认失败**

Run: `bash tests/workflow-state.sh`
Expected: FAIL（脚本不存在）

- [ ] **Step 4: 写 scripts/workflow-state.sh**

```bash
#!/usr/bin/env bash
# 续行状态独占接口（学 Comet comet-state.sh）。SKILL.md 只调本脚本，禁手改 YAML。
# 用法: workflow-state.sh [--repo R] {init|get <field>|set <field> <value>|check}
set -euo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

REPO="$PWD"
if [ "${1:-}" = "--repo" ]; then REPO="$2"; shift 2; fi
STATE="$REPO/docs/superpowers/.workflow-state.yaml"

VALID_PHASES="brainstorm spec plan tdd review done"
VALID_FIELDS="task level phase updated next artifacts.spec artifacts.plan"

die(){ echo "✗ $1" >&2; exit 1; }
in_list(){ printf '%s\n' $2 | grep -qxF "$1"; }

yget(){ # 顶层或 artifacts.* 取值
  local k="$1"
  case "$k" in
    artifacts.*) awk -v sub="${k#artifacts.}" '/^artifacts:/{f=1;next} f&&$0!~/^[[:space:]]/{f=0} f&&$1==sub":"{sub(/^[[:space:]]*[^:]+:[[:space:]]*/,"");print;exit}' "$STATE" ;;
    *) awk -v k="$k" '$1==k":"{sub(/^[^:]+:[[:space:]]*/,"");print;exit}' "$STATE" ;;
  esac
}

case "${1:-}" in
  init)
    mkdir -p "$(dirname "$STATE")"
    [ -f "$STATE" ] || cp "$PLUGIN_ROOT/templates/workflow-state.yaml" "$STATE"
    echo "✓ 状态文件就绪：$STATE" ;;
  get)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    yget "$2" ;;
  set)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    field="$2"; value="$3"
    in_list "$field" "$VALID_FIELDS" || die "未知字段 $field（允许: $VALID_FIELDS）"
    [ "$field" = "phase" ] && { in_list "$value" "$VALID_PHASES" || die "非法 phase $value（允许: $VALID_PHASES）"; }
    # 自动更新 updated
    today="$(date +%F)"
    tmp="$(mktemp)"
    awk -v field="$field" -v value="$value" -v today="$today" '
      BEGIN{set_done=0; upd_done=0}
      /^artifacts:/{inart=1}
      inart && $0!~/^[[:space:]]/ && $0!~/^artifacts:/{inart=0}
      {
        line=$0
        if(field ~ /^artifacts\./ && inart){ key=substr(field,11); if($1==key":"){ line="  " key ": " value; set_done=1 } }
        else if(field !~ /^artifacts\./ && $1==field":"){ line=field ": " value; set_done=1 }
        if($1=="updated:"){ line="updated: " today; upd_done=1 }
        print line
      }' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
    echo "✓ $field = $value（updated=$today）" ;;
  check)
    [ -f "$STATE" ] || die "状态文件不存在"
    ph="$(yget phase)"; [ -z "$ph" ] || in_list "$ph" "$VALID_PHASES" || die "phase 非法: $ph"
    sp="$(yget artifacts.spec)"; [ -z "$sp" ] || [ -f "$REPO/$sp" ] || echo "⚠ spec 文件不存在: $sp" >&2
    echo "✓ check 通过（phase=${ph:-空}）" ;;
  *) echo "用法: workflow-state.sh [--repo R] {init|get <field>|set <field> <value>|check}" >&2; exit 2 ;;
esac
```

- [ ] **Step 5: 运行确认通过**

Run: `bash tests/workflow-state.sh`
Expected: `PASS tests/workflow-state.sh`

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat: workflow-state.sh 续行状态独占接口 + schema 校验"
```

---

## Task 6: scripts/codegraph-judge.sh（detect-changes 判级守卫 + 三层降级）

**Files:**
- Create: `scripts/codegraph-judge.sh`
- Test: `tests/codegraph-judge.sh`

- [ ] **Step 1: 写失败测试 tests/codegraph-judge.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CG="$HERE/scripts/codegraph-judge.sh"
REPO="$(mktemp -d)"   # 无 codegraph 的空目录

# 无 code-review-graph 或无 graph.db → 退出码 3（不可用），输出降级提示
set +e
out="$(bash "$CG" --repo "$REPO" assess 2>&1)"; rc=$?
set -e
[ "$rc" = "3" ] || { echo "FAIL: 不可用时应退出码 3，实际 $rc"; exit 1; }
echo "$out" | grep -q "降级" || { echo "FAIL: 应提示降级"; exit 1; }
echo "PASS tests/codegraph-judge.sh"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/codegraph-judge.sh`
Expected: FAIL（脚本不存在）

- [ ] **Step 3: 写 scripts/codegraph-judge.sh**

```bash
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
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/codegraph-judge.sh`
Expected: `PASS tests/codegraph-judge.sh`

- [ ] **Step 5（可选，本机有 codegraph）：真实冒烟**

Run: `bash scripts/codegraph-judge.sh --repo ~/gst-workspace/gst-med-collect --base HEAD~10 assess`
Expected: 打印 risk 0.55 等真实摘要（验证 happy path）

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat: codegraph-judge.sh 判级守卫与三层降级"
```

---

## Task 7: 移植 hook + plugin.json 声明

**Files:**
- Create: `scripts/detect-judging-correction.py`（复制参考源全文，无需改动——它只读 transcript_path 与 prompt）
- Modify: `.claude-plugin/plugin.json`
- Test: `tests/hook.sh`

- [ ] **Step 1: 复制 hook 脚本并 chmod**

```bash
cp ~/.claude/skills/dev-workflow/detect-judging-correction.py scripts/
chmod +x scripts/detect-judging-correction.py
```

- [ ] **Step 2: 写测试 tests/hook.sh（正例注入 + 反例静默）**

```bash
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
```

- [ ] **Step 3: 运行确认通过**

Run: `bash tests/hook.sh`
Expected: `PASS tests/hook.sh`

- [ ] **Step 4: 在 plugin.json 声明 hook**

把 Task 1 的 plugin.json 增补 `hooks` 段：

```json
{
  "name": "dev-workflow",
  "version": "0.1.0",
  "description": "分级开发工作流路由（L0–L4）：判级加固、跨 session 续行、跨项目自主进化、codegraph 判级集成。",
  "author": "elvis",
  "license": "MIT",
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/detect-judging-correction.py" }
        ]
      }
    ]
  }
}
```

> **风险核实点**：实现时用当前 Claude Code 版本确认 plugin.json 的 hooks schema 是否如上（或需放独立 `hooks/hooks.json`）。以官方文档为准，若不同则按官方格式调整后再提交。

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat: 移植判级纠正 hook 并在 plugin.json 声明"
```

---

## Task 8: skills/dev-workflow/SKILL.md（移植 + 路径改写 + codegraph 段 + 续行改调脚本）

**Files:**
- Create: `skills/dev-workflow/SKILL.md`

- [ ] **Step 1: 复制参考源 SKILL.md 全文**

```bash
cp ~/.claude/skills/dev-workflow/SKILL.md skills/dev-workflow/SKILL.md
```

- [ ] **Step 2: 全局路径改写**

把所有 `~/.claude/skills/dev-workflow/` 替换为 `${CLAUDE_PLUGIN_ROOT}/scripts/`；`LEARNINGS.md` 的引用改为「数据区（`learnings.sh` 自动定位）」描述。

- [ ] **Step 3: 「跨 session 续行」段改为调脚本**

把原「手改 `.workflow-state.yaml`」的 4 条约定改为：开工 `workflow-state.sh check`/`get`；定级 `set level/task/phase`；过阶段 `set phase/next`；收尾 `set phase done`。强调「禁手改，只调脚本」。

- [ ] **Step 4: 新增「codegraph 辅助判级」段**

写明：开工前（L2 及以上或判级拿不准）跑 `codegraph-judge.sh --repo <repo> assess`；退出码 3 则降级人工判级；按输出的风险/测试缺口校准级别并定 TDD 靶向；背离则记 `判级/图风险背离`。L4 不跑。

- [ ] **Step 5: 「自主进化」段路径与命令对齐**

`learnings.sh` 调用改为 `${CLAUDE_PLUGIN_ROOT}/scripts/learnings.sh`；hook 描述改为「由 plugin.json 声明，启用即生效」。

- [ ] **Step 6: 校验 skill frontmatter**

确认顶部 `name: dev-workflow` 与 `description`（含 L0–L4 触发关键词）保留，使 skill 能被正确触发。

- [ ] **Step 7: 提交**

```bash
git add -A && git commit -m "feat: SKILL.md 插件化 —— 路径改写、续行调脚本、新增 codegraph 段"
```

---

## Task 9: bin/init 安装器 + README 回填

**Files:**
- Create: `bin/init`
- Modify: `README.md`
- Test: `tests/init.sh`

- [ ] **Step 1: 写测试 tests/init.sh（沙箱 HOME + 沙箱 repo）**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"; export HOME="$SBOX/home"; mkdir -p "$HOME"
REPO="$SBOX/repo"; mkdir -p "$REPO"; (cd "$REPO" && git init -q)
export CLAUDE_PLUGIN_ROOT="$HERE"

bash "$HERE/bin/init" --repo "$REPO" --yes >/dev/null
# 数据区与 LEARNINGS 应生成
[ -f "$HOME/.claude/dev-workflow/LEARNINGS.md" ] || { echo "FAIL: 数据区未建"; exit 1; }
# .workflow-state.yaml 应进 repo .gitignore
grep -q "workflow-state.yaml" "$REPO/.gitignore" || { echo "FAIL: 未写 gitignore"; exit 1; }
echo "PASS tests/init.sh"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/init.sh`
Expected: FAIL（bin/init 不存在）

- [ ] **Step 3: 写 bin/init**

```bash
#!/usr/bin/env bash
# dev-workflow 安装器：建数据区、检测引导依赖与 codegraph、确保 gitignore。
set -euo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$PLUGIN_ROOT/scripts/lib.sh"

REPO="$PWD"; YES=0
while [ "${1:-}" ]; do case "$1" in --repo) REPO="$2"; shift 2;; --yes|-y) YES=1; shift;; *) shift;; esac; done

# 1. 数据区 + LEARNINGS
dw_ensure_learnings
echo "✓ 用户数据区：$(dw_data_dir)"

# 2. gitignore 续行状态
GI="$REPO/.gitignore"
grep -qxF "docs/superpowers/.workflow-state.yaml" "$GI" 2>/dev/null || \
  echo "docs/superpowers/.workflow-state.yaml" >> "$GI"
echo "✓ 已确保 .gitignore 忽略续行状态"

# 3. 检测伴侣 skill（superpowers）
if [ ! -d "$HOME/.claude/plugins/cache"/*superpowers* ] 2>/dev/null; then
  echo "ℹ 未检测到 superpowers —— L1 的 brainstorm/TDD/plans 等步骤将降级为内联描述。"
  echo "  建议安装以获得完整体验。"
fi

# 4. 检测 codegraph
if command -v code-review-graph >/dev/null 2>&1; then
  echo "✓ 检测到 code-review-graph —— codegraph 判级校验可用（Mode A）"
  if [ "$YES" = 1 ] || { read -rp "为本 repo 注册 codegraph MCP（解锁事前依赖查询 Mode B）? [y/N] " a; [ "$a" = y ]; }; then
    (cd "$REPO" && code-review-graph install --platform claude-code --no-hooks --no-skills --no-instructions -y) || true
  fi
else
  echo "ℹ 未检测到 code-review-graph —— 判级将纯人工进行（功能完整）。装它可解锁判级校验。"
fi
echo "✓ dev-workflow 安装完成"
```

- [ ] **Step 4: chmod + 运行确认通过**

```bash
chmod +x bin/init
bash tests/init.sh
```
Expected: `PASS tests/init.sh`

- [ ] **Step 5: 回填 README.md**

补全：安装步骤（启用插件 → `bin/init`）、三层 codegraph 降级表、用户数据区位置与「数据/代码分离」说明、依赖清单、L0–L4 简表。

- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat: bin/init 安装器 + README"
```

---

## Task 10: 可移植性总冒烟 + 全量测试

**Files:**
- Create: `tests/all.sh`

- [ ] **Step 1: 写 tests/all.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for t in lib learnings workflow-state codegraph-judge hook init; do
  bash "$HERE/$t.sh"
done
echo "=== 绝对路径扫描（不应出现个人路径）==="
! grep -rn "/Users/elvis" "$HERE/.." --include=*.sh --include=*.md --include=*.json --include=*.py 2>/dev/null | grep -v "/tests/" \
  && echo "✓ 无硬编码个人路径" || { echo "FAIL: 存在硬编码路径"; exit 1; }
echo "ALL PASS"
```

- [ ] **Step 2: 运行全量**

Run: `bash tests/all.sh`
Expected: 全部 PASS + `✓ 无硬编码个人路径` + `ALL PASS`

- [ ] **Step 3: 真实启用验证（手动）**

在 Claude Code 中以本地路径启用该 plugin，新开会话验证：① skill 能被开发需求触发；② hook 生效（判级纠正时注入提醒）；③ `learnings.sh ready`/`workflow-state.sh` 可调。记录结果到 README 的「已验证」小节。

- [ ] **Step 4: 提交**

```bash
git add -A && git commit -m "test: 全量测试与可移植性冒烟"
```

---

## 收尾（L1 SDD）

- [ ] 全部任务完成、`tests/all.sh` 通过
- [ ] 把本 spec 与 plan 从 gst-med-collect 迁入新仓库 `docs/`（或按用户偏好保留），更新 `.workflow-state.yaml` phase=done
- [ ] `requesting-code-review` 审查
- [ ] 决定是否推 GitHub（用户拍板）

## 自检覆盖（plan vs spec）

- 6 个绑死点：路径(Task 8/10)、hook 注册(Task 7)、用户数据分离(Task 2/3)、路由(Task 8 frontmatter)、依赖(Task 9)、codegraph(Task 6) —— 全覆盖。
- 脚本独占状态：learnings.sh(Task 3)、workflow-state.sh(Task 5) —— 覆盖。
- codegraph 三层降级：Task 6 + Task 9 —— 覆盖。
- 自主进化打通 codegraph：Task 4 新 category + Task 6 提示 + Task 8 SKILL 段 —— 覆盖。
- 风险（hook schema）：Task 7 Step 4 标注实现时核实。
