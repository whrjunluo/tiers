# dev-workflow 可发布 Plugin 化设计

- 日期：2026-06-15
- 级别：L1（SDD）
- 状态：设计待 review

## 背景与动机

`dev-workflow` 现为个人全局 skill（`~/.claude/skills/dev-workflow/`），已具备：分级决策树（L0–L4）、判级加固（显式判级 + tie-breaker + 边界表）、跨 session 续行（`.workflow-state.yaml` 约定）、跨项目自主进化（`LEARNINGS.md` + `learnings.sh` + UserPromptSubmit hook）。

目标是把它**独立成可发布到 GitHub 的产物**，并把代码结构知识图（`code-review-graph` / codegraph）接入以客观化判级。参考了 [Comet](https://github.com/rpamis/comet) 的设计（npm 包 + `init` 安装器 + 脚本独占状态 + 脚本/hook 驱动可靠性，且全程无 MCP）。

### 当前阻碍独立性的 6 个绑死点

1. 绝对路径（SKILL.md / hook / CLAUDE.md 全是 `/Users/elvis/...`）
2. hook 注册在个人 `settings.json`
3. 用户数据 `LEARNINGS.md` 放在 skill 目录（更新即丢、且属私人数据）
4. 路由入口依赖个人 `~/.claude/CLAUDE.md`
5. L0/L1 点名外部命令（`/office-hours`、`/qa`、`/ship`、superpowers 各 skill）
6. codegraph 是第三方工具，缺失则报错

## 目标 / 非目标

**目标**
- 形态升级为 Claude Code Plugin，零绝对路径、hook 自带、用户数据与代码分离。
- codegraph 集成「直接内置」（A 方案），三层优雅降级。
- 依赖伴侣 skill 由安装器自动装。
- 状态由脚本独占接口管理，禁止手改（学 Comet）。

**非目标（YAGNI）**
- 第一阶段不做 Comet 式完整 npm 包 / 多平台适配 / CLI（仅预留升级口）。
- 不自己捆绑/维护 MCP（codegraph 的 MCP 是第三方，仅按需注册）。
- 不做 i18n（保持中文）。
- 不直接 SQL 查 `graph.db`、不自动起 serve daemon。

## 决策记录（brainstorming 结论）

| 议题 | 决定 |
|---|---|
| 打包野心 | 分阶段：先轻量 Plugin，结构预留升级到 Comet 式包 |
| codegraph/MCP | **A 直接内置**：`detect-changes` guard 脚本 + 检测到 codegraph 就注册其现成 MCP；三层降级。C（自养 MCP）排除 |
| 依赖处理 | 安装器 `init` 自动装 superpowers 等伴侣；外部命令调用「有则用、无则降级」 |
| 状态管理 | 脚本独占（`learnings.sh` 已有 + 新增 `workflow-state.sh`），禁手改 |

## 架构

### 插件目录布局

```
dev-workflow-plugin/
├─ .claude-plugin/
│  └─ plugin.json              # 插件清单：元信息 + hooks 声明
├─ skills/
│  └─ dev-workflow/
│     └─ SKILL.md              # 决策树 + 判级 + 续行 + 进化 + codegraph（路径用 ${CLAUDE_PLUGIN_ROOT}）
├─ scripts/
│  ├─ learnings.sh             # 进化日志独占接口（count/ready/categories/add/list）
│  ├─ workflow-state.sh        # 续行状态独占接口（init/get/set/check）← 新增
│  ├─ codegraph-judge.sh       # detect-changes 判级守卫 + 三层降级 ← 新增
│  └─ detect-judging-correction.py  # UserPromptSubmit hook
├─ templates/
│  ├─ LEARNINGS.md             # 进化日志模板（含词表，首次复制到用户数据区）
│  └─ workflow-state.yaml      # 续行状态模板
├─ bin/
│  └─ init                     # 安装器（阶段一最小：建数据区 + 检测/引导依赖与 codegraph）
├─ README.md / LICENSE
```

### 数据 / 代码分离（关键）

插件目录会被更新覆盖，**用户积累数据绝不能放插件内**。

- 代码/模板：随插件走（`${CLAUDE_PLUGIN_ROOT}` 下）。
- 用户数据区：`${DEV_WORKFLOW_DATA:-$HOME/.claude/dev-workflow}/`
  - `LEARNINGS.md`（全局跨项目进化日志）
  - 续行状态仍 per-project：`<repo>/docs/superpowers/.workflow-state.yaml`（gitignore）
- 脚本启动时若用户数据区无 `LEARNINGS.md`，从 `templates/` 复制初始化。

### 路径与 hook 可移植

- SKILL.md 与脚本互引一律 `${CLAUDE_PLUGIN_ROOT}/scripts/...`。
- hook 在 `plugin.json` 声明，启用插件即生效，不写用户 `settings.json`：
  ```json
  {
    "hooks": {
      "UserPromptSubmit": [
        { "hooks": [ { "type": "command",
          "command": "${CLAUDE_PLUGIN_ROOT}/scripts/detect-judging-correction.py" } ] }
      ]
    }
  }
  ```

## 组件

### 1. 状态脚本独占（学 Comet 的 comet-state.sh）

- `learnings.sh`：已实现，迁移路径到数据区。
- `workflow-state.sh`（新增）：`init` / `get <field>` / `set <field> <value>` / `check`（schema 校验：phase 枚举、artifacts 路径存在性）。SKILL.md 续行约定改为「调脚本」而非「手改 YAML」。

### 2. codegraph 集成（A，三层降级）

`codegraph-judge.sh` 行为：
- 探测 `command -v code-review-graph` 且 `<repo>/.code-review-graph/graph.db` 存在。
  - 都在 → 跑 `code-review-graph detect-changes --brief`，输出 risk / 改动函数数 / 文件数 / test gaps。
  - 否则 → 退出码标记「不可用」，SKILL.md 降级为纯人工判级。
- 判级校准阈值（提示非硬覆盖，冲突偏严，与 tie-breaker 一致）：
  | 图信号 | 判级含义 |
  |---|---|
  | risk ≥ 0.4 / 改动文件 ≥ 8 / 有 affected flow | 至少 L1，判更低要重审 |
  | 有 test gap 且改了已有函数 | 锁 L2/L3，必须补测试，禁 L4 |
  | risk≈0 且 0 changed functions | L4 可放心 |
- TDD 靶向：detect-changes 点名的 untested 函数 = TDD 首批测试目标。

三层能力：① 无 codegraph→人工判级；② 有图→判级校验+TDD 靶向（Mode A）；③ 注册 MCP→事前依赖查询（Mode B）。

### 3. 安装器 `bin/init`（阶段一最小实现）

- 建用户数据区，复制模板。
- 检测伴侣 skill（superpowers 等），缺失则引导/自动安装。
- 检测 codegraph：在 → 询问是否 `code-review-graph install --platform claude-code --no-instructions` 按 repo 注册 MCP（Mode B）；不在 → 提示「装它可解锁判级校验」，不强装。
- 确保 `<repo>/docs/superpowers/.workflow-state.yaml` 进 `.gitignore`。

### 4. 自主进化（保留 + 打通 codegraph）

- 机制不变：纠正→`learnings.sh add`→同 category pending≥2→开工提固化提案→人工放行。
- 新打通：codegraph 风险与我判级明显背离（判 L4 但 risk=0.55）= 一次「判级被数据纠正」→记 LEARNINGS，新增 category `判级/图风险背离`。

## 触发与路由

不再依赖个人 CLAUDE.md。靠 skill 自身 `description`（已含 L0–L4 关键词）触发；开工前三件事（进化扫描 / 续行检查 / 显式判级）写在 SKILL.md。

## 依赖

- 必需运行时：bash、awk、python3、git。
- 伴侣 skill：superpowers（brainstorming/TDD/plans/review/debugging）—— 安装器自动装；缺失时对应步骤降级为内联描述。
- gstack 命令（`/office-hours`/`/qa`/`/ship`）—— 抽象为「做什么」，有对应工具则用，无则跳过。
- 可选：`code-review-graph`（解锁 Mode A/B）。

## 错误处理与降级

- 所有外部探测失败一律静默降级，绝不打断主流程。
- 脚本对缺文件/非法字段给明确报错并退出非零，调用方据退出码降级。
- hook 检测不到判级纠正即静默退出。

## 测试策略

- `learnings.sh`：计数 0→1→2 跨阈值、category 校验、非法拒绝（已验证）。
- `workflow-state.sh`：init/set/get/check schema 校验正反例。
- `codegraph-judge.sh`：有图/无图/有图无 db 三态降级；阈值映射。
- hook：判级纠正正例注入、两类反例静默（已验证）。
- 可移植性冒烟：在临时 HOME + 临时 repo 下启用插件，验证零绝对路径、hook 生效、数据区生成。

## 分阶段交付

- **阶段一（本 spec）**：Plugin 化 + 数据分离 + workflow-state.sh + codegraph A 内置 + 最小 init + hook 声明。
- **阶段二（升级口，不在本 spec）**：Comet 式 npm 包 + 多平台适配 + 完整 CLI。

## 风险

- 插件 hook 声明的具体 schema 需按当前 Claude Code 版本核实（实现时验证）。
- codegraph MCP 注册 per-repo，多 repo 用户需每库注册（安装器引导）。
- 自主进化「记录」仍依赖 hook 提醒 + 我执行 `add`，非全自动（已知薄弱点，保留人工环节）。
