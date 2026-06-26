---
name: dev-workflow
description: Use when any development task appears, including new features, bug fixes, refactors, UI changes, implementation requests, code edits, or workflow-level choices. Automatically routes the task through L0 gstack, L1 SDD, L2 lightweight spec, L3 debugging, or L4 direct edit and executes the matching skill chain.
---

# 开发工作流路由与执行指南

## 插件路径约定

本文用 `<plugin-root>` 表示插件仓库根目录，不是 `skills/dev-workflow` 目录。

本仓库结构固定为：

```text
<plugin-root>/
  skills/dev-workflow/SKILL.md
  scripts/workflow-state.sh
  scripts/learnings.sh
  scripts/codegraph-judge.sh
```

如果当前 skill 文件路径是：

```text
.../tiers/skills/dev-workflow/SKILL.md
```

那么 `<plugin-root>` 是：

```text
.../tiers
```

正确脚本路径示例：

```bash
<plugin-root>/scripts/workflow-state.sh check
```

错误示例（不要这样拼）：

```bash
<plugin-root>/skills/dev-workflow/scripts/workflow-state.sh check
```

执行脚本前按以下顺序解析：

1. `DEV_WORKFLOW_PLUGIN_ROOT`
2. `CODEX_PLUGIN_ROOT`
3. `CLAUDE_PLUGIN_ROOT`
4. 若是从本文件路径推断，则从 `skills/dev-workflow/SKILL.md` 上溯两级到仓库根目录

脚本自身也按同样规则自动推断，Codex 环境不要依赖 Claude 专属变量。

## 使用时机

每次接到新的开发任务时，先跑决策树确定级别，再按对应步骤执行。

---

## 开工前：进化检查 + 强制显式判级 + 续行检查

接到任何开发需求，**动手前必须先做这三件事**，不许闷头直接开干：

1. **进化扫描**（见下方「自主进化」）。读数据区（`learnings.sh` 自动定位），把 `status: pending` 的条目按 `category` 计数；若某 category ≥ 2，先输出固化提案等用户确认，否则保持沉默。
2. **读续行状态**（见下方「跨 session 续行」）。若检测到未完成任务，先提示用户「继续 / 换新任务」，不要无视。
3. **显式输出一行判级结论**，格式固定：

   ```
   级别 = Lx｜理由 = <一句话，对应决策树哪一问命中>
   ```

   这一行让判断可见、可被用户当场纠正。没有这一行就开始改代码 = 流程违规。

**判级 tie-breaker（拿不准时）：** 在两级之间犹豫，一律**走更严的那级**。
- L1/L2 之间拿不准 → 按 **L1**（走 SDD）
- L2/L3 之间拿不准 → 按**有回归风险**处理，补测试
- L3/L4 之间拿不准 → 按 **L3**（先复现再改）

宁可多一道流程，不漏一次回归。

---

## 决策树

```
Q0: 涉及多个已有模块的结构性重组或架构迁移？
  → 是 → L0
  → 否 → Q1

Q1: 新增了别人没有预期过的行为或结构？
  → 是 → L1
  → 否 → Q2

Q2: 如果改错了，有可能回归现有功能？
  → 是 → L2 或 L3（有测试要求）
  → 否 → L4
```

L2 vs L3 的区分：**新功能逻辑改动 → L2，线上 bug 修复 → L3**。

---

## 理解度关卡（各级通用）

动手改代码 / 写测试前，先过一道与本级匹配的理解度自检。共同退出标准：**能否在基本不返工的前提下进入下一步**。拿不准默认走更严的处理（同 tie-breaker）；过不了关卡不是只有"往深挖"一条路——也可能是**判级错了，回去重判**。

| 级别 | 动手前要"懂"的对象 | 没懂时 |
|---|---|---|
| L1 | 需求 / 设计（决策树分支、边界） | 进 `grill-me`；想跳过需用户点头（详见 L1 HARD-GATE） |
| L2 | 改动的影响面 / 回归边界 / 能否写出覆盖测试 | 跑 `codegraph-judge assess` 看 affected flow / test gap，或直接读消费方；**影响面超预期（跨模块/结构性）→ 回去重判级（可能 L1/L0）** |
| L3 | bug 的**真正根因**（不是症状冒出点） | 留在 `systematic-debugging`，别急着改；**"修复"其实是在加新行为 → 重判级（可能 L2）** |
| L4 | （风险≈0，免） | — |

---

## 设计保真验收关卡（各级通用，收尾 HARD-GATE）

理解度关卡守"动手前懂没懂"，这道关守"做完后是否按设计源完成"。**凡产出可见 UI 且有设计稿（Figma 等）的任务，不论判到 L1/L2/L3/L4，收尾标 done 前必过此关。** 纯逻辑改动、无设计稿的 UI 文案微调豁免。

> ⛔ **HARD-GATE（保真收尾强制，优先级高于"渲染无报错就算完"的直觉）**
> 凭「页面可渲染 / 关键标题在场 / 视觉上大致接近」**不算对齐设计稿**，禁止据此声明 done。必须做完下面**两步，缺一不算过**：
>
> 1. **整屏完整性核对** — 逐区块对设计稿核对「有无漏做整块区域 / 组件范式是否一致」。防止只看到局部元素就误判整屏已完成。
> 2. **逐元素量化比对** — 关键元素的设计稿量化值（尺寸 / 圆角（含单角圆角）/ 色值 / 字号字重 / 间距 / 描边）用 **DOM inspect / 实测**逐项对设计真值，**禁凭"看着像 / 渲染无报错"放行**。
>
> **取数与执行纪律：**
> - 设计真值由**取数中枢 REST 直取**（Figma REST 等：图片导出 + 节点树量化值），不要依赖视觉印象或二手描述猜测。
> - 实现可委派，但**验收必须由主流程本端完成**（preview 逐区 inspect），不能只依赖实现方自报"已对齐"。
> - 配套方法见 skill `figma-fidelity-verification`（含 REST 取真值 → 写 death-spec → 派 agent 实现 → 逐区量化验收的完整 loop，本文不重复其内容）。
>
> **未过此关不得标 done。** 自检红旗：当你准备说"对齐设计稿了 / 这个页面做完了"，但**本任务还没做整屏核对 + 逐元素 inspect**——立即停下，回到关卡。

> 状态机（L1/L2 维护 workflow-state 时）：收尾前补一个 `fidelity-verify` 阶段标记，两步都过再 `set phase done`。见下方「跨 session 续行」。

---

## codegraph 辅助判级（可选，三层降级）

L2 及以上、或判级拿不准时，跑 codegraph 守卫获取客观信号：

```bash
<plugin-root>/scripts/codegraph-judge.sh [--repo <repo>] [--base <base>] assess
```

- **退出码 0**：已输出风险摘要，按下表校准级别。
- **退出码 3**：codegraph 不可用 → 降级为纯人工判级，继续流程。

**判级校准阈值（提示非硬覆盖，冲突偏严，与 tie-breaker 一致）：**

| 图信号 | 判级含义 |
|---|---|
| risk ≥ 0.4 / 改动文件 ≥ 8 / 有 affected flow | 至少 L1，判更低要重审 |
| 有 test gap 且改了已有函数 | 锁 L2/L3，必须补测试，禁 L4 |
| risk≈0 且 0 changed functions | L4 可放心 |

**TDD 靶向**：detect-changes 点名的 untested 函数 = TDD 首批测试目标。

**打通自主进化**：若图风险与你判级明显背离（判 L4 但 risk=0.55），按一次「判级被数据纠正」记入：
```
<plugin-root>/scripts/learnings.sh add 判级/图风险背离 <project> "<note>"
```

L4 微调不跑（风险≈0，白跑）。

---

## L0 — 大型改造（gstack 完整 sprint）

**触发条件：** 跨多模块重构、架构迁移、大范围技术债清理。

**执行步骤：**
1. 用强制提问重新审视问题范围，避免过度工程（若有 `/office-hours` 工具则用）
2. 战略范围分析，确认值不值得做、做多少（若有 `/plan-ceo-review` 则用）
3. 架构方案验证，识别风险点和测试需求（若有 `/plan-eng-review` 则用）
4. 用户已授权某个外部 Agent 时，可用 `external-agent` 调 `agy` / `cursor-agent` / `grok` 做一次独立架构挑战；输出只作证据，主 Agent 负责核验与决策
5. 实现阶段：按 plan 拆分，每个子任务可独立用 worktree + 并行 Agent
6. 真实浏览器测试，自动生成 fix commit（若有 `/qa` 工具则用）
7. CI 自动化 + PR 创建（若有 `/ship` 工具则用）

**注意：** L0 改造必须拆分为可独立合并的子任务，不要做一个超大 PR。

---

## L1 — 大功能（SDD → TDD）

**触发条件：** 新增模块、新增完整用户流程、跨多文件的全新设计。

> ⛔ **HARD-GATE（L1 强制时序，优先级高于被插入 skill 自身的终态指令）**
> `brainstorming` skill 的终态指令是「下一步 invoking writing-plans，不要调用其他 skill」——**这条对 L1 不成立，必须无视**。L1 在 brainstorming 之后、写/定稿 spec 之前，**必须先通过「理解度关卡」**，禁止从 brainstorm 直接跳到 spec/plan。
> **关卡判定**：摆出决策树各分支已落到的结论、识别到的边界情况、仍未问清的开口，自评对需求的理解度（能否写出基本不返工的 spec）。
> - **理解不足，或拿不准** → 进 `grill-me` 追问，收敛到理解足够才退出。**未通过关卡禁止写 spec / 调 `writing-plans` / 建 specs 目录。**
> - **自评已足够**（决策树全分支有结论、边界已探、无开口）→ 仍须**显式向用户提议「理解已足够，建议跳过深度 grill 直接写 spec」并取得用户点头**，方可跳过 grill。未经检验的信心不算通过；自己拍板跳过 = 流程违规。
> 自检红旗：当你发现自己"准备写 spec / 准备调 writing-plans / 准备建 specs 目录"，但**本任务还没过理解度关卡**——立即停下，回到关卡。

**执行步骤：**
1. `brainstorming` skill — 澄清需求，提出 2-3 方案，用户确认，起草设计文档到 `docs/superpowers/specs/`
2. **理解度关卡（必经）** — 按上方 HARD-GATE 判定：理解不足/拿不准 → 进第 3 步 grill；自评足够 → 向用户提议跳过、**取得点头后**直接进第 4 步。
3. **`grill-me` skill（理解度不足时触发，本插件内置）** — 对着设计文档追问，逐个解决决策树分支、暴露边界情况，把答案回填进文档，理解收敛达标才退出。
   > 内置 `grill-me` 是零依赖基线。若用户自行装了更强的追问 skill（如 `mattpocock/skills` 的 `grill-with-docs`，锚定 CONTEXT.md/ADR、边问边更新文档），则优先用它。
4. `writing-plans` skill — 基于已收敛的设计文档写 plan 到 `docs/superpowers/plans/`
5. `test-driven-development` skill — 先写失败测试，再实现，测试通过后提交
6. `requesting-code-review` skill — 请求代码审查
7. `verification-before-completion` skill — 验证功能符合 spec 后关闭任务

> L0 的范围审视/架构验证阶段同样可以用 `grill-me` 追问设计；L2 只有轻量 spec，一般不必；L3/L4 无设计文档，跳过。

---

## L2 — 中型迭代（轻量 spec → TDD）

**触发条件：** 修改已有逻辑，影响 ≥3 个文件，但不是全新模块。

**执行步骤：**
1. 写一段简短的需求说明（不需要完整 brainstorming，3-5 句话描述目标和边界）
2. **理解度关卡（轻量，见上）** — 一句话自检：谁在消费这块 / 回归边界在哪 / 能写出覆盖测试吗？拿不准 → `codegraph-judge assess` 或读消费方；影响面超预期 → 回去重判级。
3. `test-driven-development` skill — 先写覆盖改动点的失败测试
4. 实现，让测试通过
5. （可选）`requesting-code-review` skill — 影响面大时使用

---

## L3 — Bug 修复（调试优先）

**触发条件：** 线上问题、行为回归、测试失败的已知 bug。

**执行步骤：**
1. `systematic-debugging` skill — 系统性定位根因，不要凭感觉猜
2. **根因关卡（轻量，见上）** — 写修复前自检：我定位到真正根因了，还是在改症状冒出点？答不上 → 留在 systematic-debugging 别动手；若"修复"其实是加新行为 → 回去重判级（可能 L2）。
3. 写一个能复现 bug 的失败测试（先红）
4. 修复，让测试变绿
5. 确认没有引入新回归后提交

---

## L4 — 文案/样式微调（直接写）

**触发条件：** 纯 UI 文字、颜色、间距调整，不涉及任何逻辑变化。

**执行步骤：**
1. 直接修改，无需 spec 或测试
2. 视觉确认改动符合预期后提交

---

## 可委派的协作 CLI（各级可选杠杆）

把子任务委派给外部编码 agent CLI（搜集信息 / 实现 / 交叉审核），统一走 **`external-agent` skill** —— 一个 runner、一套路由策略。详见该 skill 的 SKILL.md，这里只给路由速记：

```bash
python3 <plugin-root>/scripts/external_agent.py --agent <name> --cd "$PWD" \
  --PROMPT "bounded task" [--mode review|delegate] [--format text|json] [--SESSION_ID id] [--context git]
```

| agent | 家族 | 默认角色 |
|---|---|---|
| `codex` | OpenAI | 执行（算法 / 补丁 diff） |
| `cursor` | 多模型 | 执行 / 审查（仓库感知） |
| `grok` | xAI | 搜集 / 交叉审查（联网） |
| `antigravity`(`agy`) | Google | 搜集 / 审查（gemini 个人版已停用的继任者） |
| `mimo` | 小米 | 国内兜底 |

- **搜集** → `--mode review`（只读）：联网→`grok`，啃大库→`antigravity`。
- **执行** → `--mode delegate`（可写，需用户授权）：仓库内→`cursor`/`codex`，纯算法→`codex`，国内→`mimo`。
- **交叉审核** → `--mode review`，同一产物丢给 **≥2 个不同家族** 的 agent（如 `codex`+`grok`+`antigravity`），主 Agent 汇总裁决。
- 派之前 `--list` 查可用性；`--SESSION_ID` 多轮续接。

**纪律**：委派不降级流程——判级、理解度关卡、TDD、人工评审仍由本工作流主导；agent 产出是证据、不是免检的最终答案，必须过本级关卡校验。`--mode delegate`（可写）须用户授权、且只在 `--cd` 内。`--model` 非用户明确指定不要传。

---

## 常见判断边界

| 情况 | 正确级别 |
|---|---|
| 新增一个已有模式的 API 接口 | L2（改已有逻辑，有回归风险） |
| 新增全新的问卷流程 | L1（新行为，需要 SDD） |
| 把多个 store 合并重构 | L0（结构性重组） |
| 修复某个按钮点击没反应 | L3（bug） |
| 改按钮颜色 / 文案 / 间距 | L4 |
| 改按钮点击后的跳转逻辑 | L3 或 L2（看是否有回归风险，拿不准按 L2） |
| 给已有接口加一个可选参数 | L2（有回归风险） |
| 改已有接口的返回结构 / 字段含义 | L2（下游可能回归，必须补测试） |
| 调整某个 store 的字段或 action | L2（多处消费，有回归风险） |
| 新增一个独立的工具函数（无人依赖） | L4（无回归面）；一旦被多处引用就升 L2 |
| 改数据库迁移 / schema | L2 起步，跨表结构性调整升 L0 |
| 复制现有页面改文案做一个新页面 | L4（纯文案）；若新增逻辑分支则 L2 |
| 修一个偶现的线上 bug | L3（必须先复现再改） |
| 升级依赖 / 改构建配置 | L2（可能回归），波及面大升 L0 |

---

## 跨 session 续行（脚本独占接口）

让一个 L0/L1 任务跨多个对话不丢进度。**脚本独占接口（学 Comet comet-state.sh）。禁手改 YAML。**

**状态文件：** 每个项目按需生成 `docs/superpowers/.workflow-state.yaml`（加进 `.gitignore`，属工作态、不进版本库）。仅 L0/L1 需要维护；L2–L4 太短，可跳过。

**格式**（字段结构刻意设计成将来脚本可直接接管）：

```yaml
task: 一句话描述当前需求
level: L1
phase: spec          # brainstorm | grill | spec | plan | tdd | review | fidelity-verify | done
artifacts:
  spec: docs/superpowers/specs/YYYY-MM-DD-xxx-design.md
  plan: ""
updated: YYYY-MM-DD
next: 下一步具体该做什么
```

**维护约定：**
1. **开工时**：跑 `<plugin-root>/scripts/workflow-state.sh check`。如果输出「无续行状态」，直接继续判级；如果已有状态，再 `get phase` / `get task` / `get next`。若 phase != done 且非空，提示续行：「检测到未完成的 {level} 任务【{task}】，停在 {phase}，下一步 {next}。继续，还是换新任务？」
2. **定级后**：跑 `workflow-state.sh init`（首次创建），再 `set task/level/phase`。
   > L1 阶段流转：`brainstorm` →（理解度关卡）→ 理解不足则 `set phase grill`、收敛后再 `set phase spec`；自评足够且用户点头可直接 `set phase spec`。禁止 brainstorm 不经关卡判定直接跳 spec。
3. **每过一个阶段**：`set phase/next`，有 spec/plan 则 `set artifacts.spec/artifacts.plan`。
4. **收尾（仅 L0/L1）**：若本任务产出可见 UI 且有设计稿，先 `set phase fidelity-verify`，过「设计保真验收关卡」两步后再 `set phase done`；无 UI 改动则直接 `set phase done`。脚本自动更新 `updated`。

---

## 自主进化（全局，跨项目）

让这套工作流参考真实使用方式自我演进。事实源是数据区（`learnings.sh` 自动定位），全局共享，**计数与记录由脚本确定性完成，不靠对话记忆**。模式：自主发现、人工放行。

配套工具（均在 `<plugin-root>/scripts/`）：
- `learnings.sh` —— 记录/计数 helper：`count` / `ready` / `categories` / `add <category> <project> <note>` / `list`。`add` 会校验 category 取自词表、原子追加，并回报当前计数是否达阈值。
- `detect-judging-correction.py` —— UserPromptSubmit hook（由 `plugin.json` 声明，启用插件即生效）：用户提交消息时回看上一轮，若疑似纠正判级则注入提醒，让我别忘了记录。检测不到一律静默。

### 记录（被动积累）

每当**用户纠正我一次判级**（hook 通常会提醒），或某 tie-breaker 事后被证伪/证实，立即用脚本记录：

```
<plugin-root>/scripts/learnings.sh add <category> <project> "<note>"
```
- `category` 必须取自词表（脚本会拒绝非法值）；同类纠正务必贴同一标签，否则计数失效。确属新类时先在数据区（`learnings.sh` 自动定位）词表补一行再 add。
- `note` 写清「我原判 Lx → 用户纠正为 Ly，因为…」。

hook 只是"提醒"不是"代劳"——它不会自动写记录，记不记仍由我执行 `add`。这是本机制保留的人工环节。

### 检查与提案（开工时触发）

每次本 skill 被调用，作为「开工前」第 1 步：跑 `<plugin-root>/scripts/learnings.sh ready`（等价于按 `category` 数 `pending`）-> 任一 category ≥ 2 即输出提案，否则沉默：

> 📈 工作流进化提案：`<category>` 类已被你纠正 N 次（项目 A、项目 B）。建议把「<具体规则>」固化进边界表 / tie-breaker。确认固化吗？

### 固化（人工放行后）

- **用户确认** → 编辑本 SKILL.md（把规则写进边界表或 tie-breaker），并把相关条目 `status` 改为 `folded`。
- **用户否决** → 相关条目 `status` 改为 `dropped`，不再计入。

固化是改全局核心 skill 的动作，**必须用户点头**，绝不自动重写。
