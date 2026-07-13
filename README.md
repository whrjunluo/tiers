# tiers

[![CI](https://github.com/whrjunluo/tiers/actions/workflows/ci.yml/badge.svg)](https://github.com/whrjunluo/tiers/actions/workflows/ci.yml)

> 按风险与验证深度给开发任务分级（L0–L4）并路由到对应工作流的 Claude Code / Codex 插件。Claude Code 里通过 `/` 菜单使用；Codex 里会在开发需求中自动触发。

接到一个开发需求，先判它属于哪一级（从 L0 大型改造到 L4 文案微调），再走对应的工作流——减少“小改动当大事做”的过度工程，也减少“大改动当小事做”的漏测回归。插件还能跨 session 续行、按你的纠正自我进化，并可选接入 codegraph 做客观判级。

## 它能做什么

- **分级决策树（L0–L4）+ 判级加固**：显式判级输出、tie-breaker（拿不准走更严级别）、边界示例表。
- **跨 session 续行 + 完成证据门**：L0/L1 与高风险业务 L2/L3 维护项目状态；测试、真实请求、codegraph、外部评审和残余风险证据不齐时，脚本拒绝进入 done。
- **跨项目自主进化**：你纠正判级 → 积累 → 同类够阈值 → 提案把规则固化进 skill（人工放行）。
- **codegraph 判级集成**：装了 `code-review-graph` 时用客观风险分校准级别；没装则自动降级为纯人工判级。
- **依赖 doctor + 内置兜底**：检测 skills / CLI / MCP 能力，输出 base / enhanced / full 模式；缺增强依赖时不阻塞核心工作流。
- **对抗评审 provider 分层**：没有外部模型时走内置 checklist；有平台子代理、多模型或外部 CLI 时升级为只读交叉评审。
- **统一外部 Agent 委派**：一个 runner 路由 codex / cursor / grok / mimo / opencode / antigravity（agy）；`--cross-review a,b` 冻结同一输入并只在两个不同家族成功返回时形成 quorum。超时会沉淀为跨会话 provider 健康标记和建议超时。委派不降级工作流，主 Agent 负责核验。

---

## 安装

### Claude Code（推荐，从 GitHub 安装）

在 Claude Code 里：

```
/plugin marketplace add whrjunluo/tiers
/plugin install dev-workflow@tiers
```

- 安装时选 **user scope**，让所有项目、终端与桌面/网页客户端都生效。
- 装完**完全重启 Claude Code**（退出进程重开，不只是新开对话），让 skill 与 hook 加载。
- 验证：`/` 菜单出现 `dev-workflow:dev-workflow`、`dev-workflow:grill-me`、`dev-workflow:external-agent`。

### Codex（从源码安装）

```bash
git clone https://github.com/whrjunluo/tiers.git
cd tiers
bash bin/install-codex
```

`install-codex` 是**机器级一次性安装**，会：把仓库注册为 Codex 本地 marketplace、在 `config.toml` 启用插件、把 `dev-workflow`、`grill-me` 与 `external-agent` 三个 skill 链接进 `$CODEX_HOME/skills/`（默认 `~/.codex`，旧同名 skill 先备份）、初始化全局数据区。装完**重启 Codex 或新开会话**。

加 `--install-deps` 会**一并把伴侣 skill 装好**（Codex 走 skill 文件，非 `/plugin`）：

```bash
bash bin/install-codex --install-deps
# 自动 npx skills add：obra/superpowers（L1 完整链）、mattpocock/skills（grill-with-docs）
```

不加则只打印这两条命令，让你手动决定。

### Cursor（从源码安装）

```bash
git clone https://github.com/whrjunluo/tiers.git
cd tiers
bash bin/install-cursor
```

`install-cursor` 是**机器级一次性安装**，会：把 `dev-workflow`、`grill-me`、`external-agent` 三个 skill 链接进 `~/.cursor/skills/`（旧同名 skill 先备份）、初始化跨工具统一的全局数据区。装完 **Reload Window 或完全重启 Cursor**，让 skill 索引重新加载。

- 验证：Agent 里输入 `/` 能看到 `dev-workflow` / `grill-me` / `external-agent`，或直接描述开发需求触发自动判级。
- 同样支持 `--install-deps` 一并安装伴侣 skill（`npx skills add`）。
- **关于 hook**：Cursor 的 `beforeSubmitPrompt`（对应 Claude 的 `UserPromptSubmit`）只能放行/拦截、**不能向模型注入上下文**，故不安装"判级纠正提醒"hook。该能力由常驻的 `dev-workflow` skill 兜底——判级被纠正时 Agent 会主动用 `learnings.sh` 记录，**进化功能完整**，仅少了 Claude/Codex 上那层自动提醒。

> Cursor 也认 `.cursor-plugin/plugin.json`，所以本仓库同时是一个合法的 Cursor 插件；若日后上架 Cursor Marketplace 或用本地插件目录（`~/.cursor/plugins/local/`）安装，同一份 `skills/` 可直接复用。

### 更新本机安装

源码 checkout 已经是目标版本时，用一个命令刷新插件缓存和 skill 软链：

```bash
bash bin/update --codex          # 只更新 Codex
bash bin/update --cursor         # 只更新 Cursor
bash bin/update --all            # 两端都更新
```

省略平台参数时会自动更新当前检测到的安装。需要先从远端拉取再刷新时加 `--pull`；为避免覆盖本地工作，dirty worktree 会拒绝拉取：

```bash
bash bin/update --pull --codex
```

更新命令从 plugin manifest 读取版本、重建对应缓存链接，并保留 `~/.dev-workflow/` 中的学习记录和 provider 健康状态。完成后重启 Codex/新开会话，或在 Cursor 执行 Reload Window。

安装后可随时跑 doctor 看当前能力等级：

```bash
bash bin/doctor --repo <你的项目路径>
```

---

## 初始化项目（可选）

首次使用时数据区会自动创建，**通常无需手动初始化**。只有当你想让插件额外做这两件事时，才在项目根目录运行 `bin/init`：

1. 把续行状态文件加进项目 `.gitignore`
2. 检测到 `code-review-graph` 时，可选为本项目注册 codegraph MCP（解锁 Mode B 事前依赖查询）

```bash
# Codex / 已 clone 源码：在你的 clone 目录下
bash bin/init [--repo <项目路径>] [--yes]

# Claude Code（插件装在缓存里）：让 dev-workflow skill 帮你初始化当前项目即可
```

---

## 使用

装好后无需手动跑脚本。新开会话，直接描述你的开发需求即可，不需要提 `dev-workflow`：

```text
帮我给订单列表加一个批量导出
```

插件会先判级、输出一行结论，再按对应流程执行：

```text
级别 = L2｜理由 = 改已有逻辑，有回归风险
```

如果新会话没有自动判级，通常是 Codex 还没重新加载 skill 索引。先重启 Codex；排查时再临时点名 `dev-workflow`，看 skill 是否已安装成功。

### 能力模式

`dev-workflow` 不要求用户先装齐所有伴侣 skill/MCP 才能使用。运行：

```bash
bash bin/doctor --repo <项目路径>
```

会输出当前模式：

| 模式 | 含义 |
|---|---|
| `base` | 只依赖本插件内置 skill 与必需命令；L1/L2/L3 走内置 brainstorm / plan / TDD / debugging / review / verify 协议 |
| `enhanced` | 检测到 superpowers、codegraph 等增强能力；优先调用对应 skill/CLI |
| `full` | 额外具备设计保真、已建图 codegraph 等能力；可做更完整客观校验 |
| `broken` | 缺少 bash / awk / python3 / git 或本插件内置 skill 不完整 |

doctor 还会输出对抗评审能力：

| 状态 | 含义 |
|---|---|
| `built-in` | 没有额外 provider，使用内置反方 checklist |
| `external-partial` | 检测到 1 个外部 CLI，可做二次意见但不算完整交叉评审 |
| `external-ready` | 检测到 2 个以上不同家族 CLI 候选；实际调用成功并返回 `quorum=true` 才算评审通过 |

平台内子代理和多模型能力由运行时检测。触发外部交叉评审时，外部 CLI 优先，平台子代理只作不可用时的降级或额外补充，不能冒充已通过的外部 quorum。

默认不会静默安装依赖。需要自动安装可脚本化依赖时，显式运行：

```bash
bash bin/doctor --repo <项目路径> --install-deps
```

MCP、Figma 授权、外部 agent 登录这类需要用户权限的能力只会给出下一步，不会自动改本机授权状态。

### 调用外部 Agent（可选）

`external-agent` 支持多个独立 CLI：`codex / cursor / grok / mimo / opencode / antigravity`（各自的安装与登录见下方「依赖」表；`--list` 查当前已装可用的）。它们是独立 agent、各自鉴权，不是同一 agent 的不同模型。

个人免费账号及 Google AI Pro/Ultra 用户使用 Gemini 相关能力时，先安装并登录 Antigravity CLI（gemini CLI 个人版已停用）：

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy
```

之后可要求主 Agent“用 external-agent / agy / cursor-agent / grok 独立审查这次改动”。底层 runner 也可直接使用：

```bash
# 只读独立审查当前改动
python3 <plugin-root>/scripts/external_agent.py --agent antigravity \
  --cd "$PWD" --context git --PROMPT '独立审查当前改动，只报告有证据的问题'

# 授权后让 agent 实现（可写，限定在 --cd 内）
python3 <plugin-root>/scripts/external_agent.py --agent codex \
  --cd "$PWD" --mode delegate --format json --PROMPT '实现 X，输出 diff'

# 同一 diff 的双家族只读评审；JSON 可直接登记为完成证据
python3 <plugin-root>/scripts/external_agent.py --cross-review agy,mimo \
  --cd "$PWD" --context git --format json --PROMPT '只报告有证据的问题' \
  > docs/superpowers/.workflow-evidence/external-review.json
```

`--agent` 可选 `codex / cursor / grok / mimo / opencode / antigravity`。`--list` 同时显示 family、`health_status`、`routing_priority` 和 `recommended_timeout_seconds`；首次超时标记为 `slow` 并提高建议值，当前存在失败 streak 就降为 `deprioritized`，连续两次失败升级为 `degraded`，恢复成功后保留 `slow` 历史。调度默认优先健康的 `grok` / `cursor` / `mimo` 组合，慢速 `antigravity` 放到后备位；用户明确指定时仍会调用并报告状态。省略 `--timeout` 时自动采用 provider 建议值，显式传值仍是本次硬上限。`--cross-review` 只读调用逗号分隔的多个 reviewer，输出 artifact hash、repository fingerprint、生成时间、逐 reviewer 结果、成功 family 和 quorum；完成门只接受 24 小时内且仍匹配当前仓库的报告。`--context git` 会发送当前 staged/unstaged diff；不要包含密钥、`.env`、完整敏感 payload 或无关私有文件。

## 脚本路径

所有脚本在仓库根目录的 `scripts/` 下（不在 `skills/dev-workflow/` 下）。以仓库根为 `<plugin-root>`：

```bash
<plugin-root>/scripts/workflow-state.sh check     # 正确
<plugin-root>/scripts/workflow-state.sh complete  # 证据齐全后唯一合法的 done 入口
<plugin-root>/scripts/workflow-state.sh start <task> <level>  # sealed 后开始下一任务
<plugin-root>/scripts/workflow-state.sh goal "<objective>"  # 仅接管用户已设置的 Goal
<plugin-root>/scripts/workflow-state.sh continue-goal "<objective>"  # 自动续行
<plugin-root>/skills/dev-workflow/scripts/...      # 错误，此路径不存在
```

`workflow-state.sh check` 在新项目没有状态文件时会输出「无续行状态」并正常退出。`complete` 通过后会写入完成时间、repository fingerprint 和 requirements hash；sealed 状态不可再 `set` 或重复完成，必须用 `start` 开下一任务。后续仓库继续开发不会使历史 done 状态失效。

业务、请求与保真证据的 `result:` 必须有且仅有一行，内容为 `result: PASS`；仅有非空结果、写入失败结果或同时写入冲突结果都不会通过完成门。请求证据另外记录 `method:`、`url:` 和三位 `status:`，状态码按被验证路径的预期填写，不限定为 2xx。

L0–L3 在进入执行 phase 前还必须通过 `understand`：L0 提交架构边界/迁移/回滚证据，L1 提交需求验收/非目标，L2 提交影响面/测试边界，L3 提交稳定复现/根因。状态保存 scope 与 evidence SHA-256，手改 `status` 或替换证据不能绕过。Goal 模式只接管用户已创建的目标；objective 原文不落盘，相同目标续行复用有效理解度，目标变化会重置为 `pending`。

Goal 模式还要求自治确认：AI 依次作为提案者、反方审查者和裁决者，记录 2–3 个方案、reviewer provenance、最终选择、假设和残余风险。只有 `boundary: safe`、`requires_user: false` 的 PASS artifact 能通过 `workflow-state.sh confirm`；删除数据、强制推送、发布/部署、付费、凭证/隐私和权限操作必须暂停。自治结果不得表述为用户已确认。

## 分级速查

| 级别 | 典型场景 | 工作流 |
|---|---|---|
| **L0** 大型改造 | 跨模块重构、架构迁移 | 范围审视 → 架构验证 → 实现 → QA → 发布 |
| **L1** 大功能 | 新增模块 / 跨文件设计 | brainstorm → spec → grill-me → plan → TDD → review |
| **L2** 中型迭代 | 改已有逻辑，≥3 文件 | 轻量 spec → TDD → 条件评审；高风险业务闭环强制状态/外部评审/证据门 |
| **L3** Bug 修复 | 线上回归 / 行为问题 | 系统性调试 → 复现测试 → 修复 |
| **L4** 文案/样式 | 纯 UI 文字 / 样式 | 直接写，无需 spec 或测试 |

## codegraph 集成（可选，三层降级）

| 你的环境 | 插件行为 |
|---|---|
| 未装 `code-review-graph` | 纯人工判级（决策树 + tie-breaker），**功能完整** |
| 装了 + 项目已建图 | `detect-changes` 客观风险分校准级别 + TDD 靶向 |
| 上面 + 注册了 MCP | 再加“动手前查依赖”的事前预判 |

## 数据存哪（代码与数据分离，更新插件不丢数据）

| 数据 | 位置 | 作用域 |
|---|---|---|
| 进化日志 `LEARNINGS.md` | `$DEV_WORKFLOW_DATA`；未设时统一为 `~/.dev-workflow/`（Claude / Codex / Cursor 共享一份，首次运行自动从旧的 `~/.codex/dev-workflow`、`~/.claude/dev-workflow` 迁移） | 全局跨工具、跨项目 |
| 外部 agent 健康状态 `external-agent-health.json` | `$DEV_WORKFLOW_DATA`；未设时为 `~/.dev-workflow/` | 全局跨会话、跨项目 |
| 续行状态 | `<项目>/docs/superpowers/.workflow-state.yaml`（自动 gitignore） | 单项目 |
| 完成证据 | `<项目>/docs/superpowers/.workflow-evidence/`（自动 gitignore，不得存密钥或完整敏感 payload） | 单项目 |

## 依赖

**必需**：bash、awk、python3、git

不装这些也**完全可用**：核心路径会走内置协议；装上解锁更完整体验。`bin/doctor` 和 `bin/init` 会打印缺失能力；加 `--install-deps` 会**自动安装可脚本化的依赖**（superpowers 在 Claude 上仍需手动，见下）。

| 可选依赖 | 解锁什么 | 安装命令 |
|---|---|---|
| [superpowers](https://github.com/obra/superpowers) | L1 的 brainstorm / TDD / plans / review 完整 skill 链 | **Claude Code**：`/plugin install superpowers@claude-plugins-official`<br>**Codex / 其他**：`npx skills@latest add obra/superpowers` |
| [code-review-graph](https://github.com/nicobailon/code-review-graph) | codegraph 判级校验（上表 Mode A/B） | `uv tool install code-review-graph`（或 `pipx install` / `pip install`） |
| [mattpocock/skills](https://github.com/mattpocock/skills) 的 `grill-with-docs` | 内置 `grill-me` 的升级（锚定 CONTEXT.md / ADR），装了即优先用 | `npx skills@latest add mattpocock/skills` |
| `figma-fidelity-verification` skill / MCP bundle | UI 设计稿保真验收的取数与量化核对 | 按该 skill/MCP bundle 的安装说明完成授权；未安装时走内置人工验收 checklist |
| [Antigravity CLI](https://antigravity.google/) | `external-agent` 调用 Antigravity 独立二次意见 | `curl -fsSL https://antigravity.google/cli/install.sh \| bash`，然后运行 `agy` 登录 |
| Cursor Agent CLI | `external-agent` 调用 Cursor Agent 独立二次意见 | 安装 Cursor Agent CLI 后运行 `cursor-agent login` |
| Grok CLI | `external-agent` 调用 Grok 独立二次意见 | 安装 Grok CLI 后运行 `grok login` |
| OpenCode CLI | `external-agent` 调用 opencode（开源、自配 provider） | 安装后确保 `opencode` 在 PATH（把其安装目录的 `bin/opencode` 软链到已在 PATH 的目录），并 `opencode auth login` 配置 provider |

> superpowers 在 Claude Code 须通过官方插件安装（命令行无法自动完成）；其他平台安装其 skill 文件即可。

## 内置 skills

- `dev-workflow` — 工作流路由主 skill。
- `grill-me` — L0/L1 设计文档定稿前追问一轮、补边界。Vendored from [mattpocock/skills](https://github.com/mattpocock/skills)（MIT © 2026 Matt Pocock，见 `LICENSES/grill-me-MIT.txt`）。
- `external-agent` — 统一外部 agent 委派：支持单 agent 调用和 `--cross-review` 双家族 quorum，包含 `--mode review|delegate`、`--format text|json`、`--SESSION_ID`、`--context git`、`--list`。codex/gemini 适配解析逻辑参考自 [GuDaStudio/skills](https://github.com/GuDaStudio/skills)（MIT），其余为本仓原创，见 `LICENSES/collaborating-skills-MIT.txt`。

## 诊断脚本

- `bin/doctor` / `scripts/dependency-doctor.sh` — 输出当前机器和项目的能力矩阵；默认只检测，`--install-deps` 才安装可脚本化依赖。

## 平台兼容

同一份 `skills/`、`scripts/` 服务三端：Claude Code 通过 `.claude-plugin/`，Codex 通过 `.codex-plugin/`，Cursor 通过 `.cursor-plugin/`（skill 链接进 `~/.cursor/skills/`）。`hooks.json` 的"判级纠正提醒"hook 仅 Claude/Codex 启用；Cursor 不支持 prompt 提交时注入上下文，改由常驻 skill 兜底。脚本用 `DEV_WORKFLOW_PLUGIN_ROOT` / `CODEX_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` / `CURSOR_PLUGIN_ROOT` 统一解析路径，无任何硬编码绝对路径。

## License

MIT（`grill-me` 单独遵循其上游 MIT，见 `LICENSES/`）。
