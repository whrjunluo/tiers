# tiers

[![CI](https://github.com/whrjunluo/tiers/actions/workflows/ci.yml/badge.svg)](https://github.com/whrjunluo/tiers/actions/workflows/ci.yml)

> 按风险与验证深度给开发任务分级（L0–L4）并路由到对应工作流的 Claude Code / Codex 插件。Claude Code 里通过 `/` 菜单使用；Codex 里会在开发需求中自动触发。

接到一个开发需求，先判它属于哪一级（从 L0 大型改造到 L4 文案微调），再走对应的工作流——减少“小改动当大事做”的过度工程，也减少“大改动当小事做”的漏测回归。插件还能跨 session 续行、按你的纠正自我进化，并可选接入 codegraph 做客观判级。

## 它能做什么

- **分级决策树（L0–L4）+ 判级加固**：显式判级输出、tie-breaker（拿不准走更严级别）、边界示例表。
- **跨 session 续行**：每个项目一份状态文件，脚本独占读写，换会话不丢进度。
- **跨项目自主进化**：你纠正判级 → 积累 → 同类够阈值 → 提案把规则固化进 skill（人工放行）。
- **codegraph 判级集成**：装了 `code-review-graph` 时用客观风险分校准级别；没装则自动降级为纯人工判级。

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
- 验证：`/` 菜单出现 `dev-workflow:dev-workflow` 和 `dev-workflow:grill-me`。

### Codex（从源码安装）

```bash
git clone https://github.com/whrjunluo/tiers.git
cd tiers
bash bin/install-codex
```

`install-codex` 是**机器级一次性安装**，会：把仓库注册为 Codex 本地 marketplace、在 `config.toml` 启用插件、把 `dev-workflow` 与 `grill-me` 两个 skill 链接进 `$CODEX_HOME/skills/`（默认 `~/.codex`，旧同名 skill 先备份）、初始化全局数据区。装完**重启 Codex 或新开会话**。

加 `--install-deps` 会**一并把伴侣 skill 装好**（Codex 走 skill 文件，非 `/plugin`）：

```bash
bash bin/install-codex --install-deps
# 自动 npx skills add：obra/superpowers（L1 完整链）、mattpocock/skills（grill-with-docs）
```

不加则只打印这两条命令，让你手动决定。

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

## 脚本路径

所有脚本都在仓库根目录的 `scripts/` 下，不在 `skills/dev-workflow/` 下。

如果仓库 clone 到 `~/gst-workspace/tiers`，正确路径是：

```bash
~/gst-workspace/tiers/scripts/workflow-state.sh check
```

不是：

```bash
~/gst-workspace/tiers/skills/dev-workflow/scripts/workflow-state.sh check
```

`workflow-state.sh check` 在新项目没有状态文件时会输出「无续行状态」并正常退出。

## 分级速查

| 级别 | 典型场景 | 工作流 |
|---|---|---|
| **L0** 大型改造 | 跨模块重构、架构迁移 | 范围审视 → 架构验证 → 实现 → QA → 发布 |
| **L1** 大功能 | 新增模块 / 跨文件设计 | brainstorm → spec → grill-me → plan → TDD → review |
| **L2** 中型迭代 | 改已有逻辑，≥3 文件 | 轻量 spec → TDD →（可选）review |
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
| 进化日志 `LEARNINGS.md` | `$DEV_WORKFLOW_DATA`；未设时 Claude 默认 `~/.claude/dev-workflow/`、Codex 默认 `~/.codex/dev-workflow/` | 全局跨项目 |
| 续行状态 | `<项目>/docs/superpowers/.workflow-state.yaml`（自动 gitignore） | 单项目 |

## 依赖

**必需**：bash、awk、python3、git

不装这些也**完全可用**（自动降级）；装上解锁更完整体验。`bin/init` 缺失时会打印安装命令；加 `bin/init --install-deps` 会**自动安装可脚本化的依赖**（superpowers 在 Claude 上仍需手动，见下）。

| 可选依赖 | 解锁什么 | 安装命令 |
|---|---|---|
| [superpowers](https://github.com/obra/superpowers) | L1 的 brainstorm / TDD / plans / review 完整 skill 链 | **Claude Code**：`/plugin install superpowers@claude-plugins-official`（完整，含 hook）<br>**Codex / 其他**：`npx skills@latest add obra/superpowers`（skill 文件；Codex 本就无该 hook，不算损失） |
| [code-review-graph](https://github.com/nicobailon/code-review-graph) | codegraph 判级校验（上表 Mode A/B） | `uv tool install code-review-graph`（或 `pipx install` / `pip install`） |
| [mattpocock/skills](https://github.com/mattpocock/skills) 的 `grill-with-docs` | 内置 `grill-me` 的升级（锚定 CONTEXT.md / ADR），装了即优先用 | `npx skills@latest add mattpocock/skills` |

> **为什么 superpowers 在 Claude 上不能脚本一键装**：它是 `/plugin` 斜杠命令（shell 调不了），且带一个 SessionStart hook，`npx skills add` 只搬 skill 文件会丢 hook。Codex 没有这个 Claude 专属 hook，所以那边 `npx skills add` 就是完整装法——这也是 [Comet](https://github.com/rpamis/comet) 把 Superpowers skill 文件铺进各平台 `skills/` 目录的同款思路。

## 内置 skills

- `dev-workflow` — 工作流路由主 skill。
- `grill-me` — L0/L1 设计文档定稿前追问一轮、补边界。Vendored from [mattpocock/skills](https://github.com/mattpocock/skills)（MIT © 2026 Matt Pocock，见 `LICENSES/grill-me-MIT.txt`）。

## 平台兼容

同一份 `skills/`、`scripts/`、`hooks.json` 同时服务两端：Claude Code 通过 `.claude-plugin/`，Codex 通过 `.codex-plugin/`。脚本用 `DEV_WORKFLOW_PLUGIN_ROOT` / `CODEX_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` 统一解析路径，无任何硬编码绝对路径。

## License

MIT（`grill-me` 单独遵循其上游 MIT，见 `LICENSES/`）。
