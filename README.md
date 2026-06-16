# tiers

分级开发工作流路由插件（skill 命令为 `/dev-workflow`），优先兼容 Codex，同时保留 Claude Code 可用的目录与 hook 配置。根据需求复杂度（L0-L4）自动路由到对应工作流，减少判级歧义、漏测风险和跨 session 进度丢失。

## 功能

- **分级决策树**（L0 大型改造 -> L4 文案/样式）+ 判级加固（显式判级输出 + tie-breaker + 边界表）
- **跨 session 续行**：per-project 状态文件，脚本独占读写
- **跨项目自主进化**：纠正积累 → 阈值提案 → 人工放行固化规则
- **codegraph 判级集成**：三层优雅降级

## 新电脑安装 Codex

在新电脑上先 clone 这个仓库，然后运行安装脚本：

```bash
git clone <your-repo-url> ~/gst-workspace/tiers
cd ~/gst-workspace/tiers
bash bin/install-codex --yes
```

安装脚本会做这些事：

1. 把本仓库注册成 Codex 本地 marketplace：`~/.codex/plugins/local-marketplace`
2. 启用插件配置：`[plugins."dev-workflow@local"] enabled = true`
3. 创建 Codex 当前可识别的 skill 入口：
   - `~/.codex/skills/dev-workflow` -> 本仓库 `skills/dev-workflow`
   - `~/.codex/skills/grill-me` -> 本仓库 `skills/grill-me`
4. 如果本机已有旧版同名 skill，会先移到 `~/.codex/skills-backup/`
5. 初始化全局数据区：`~/.codex/dev-workflow/LEARNINGS.md`

装完后需要**新开一个 Codex 会话或重启 Codex**，让 skill 索引重新加载。

## 每个项目初始化

插件装好后，进入任意项目根目录运行：

```bash
<plugin-root>/bin/init [--repo <path>] [--yes]
```

如果已经把仓库 clone 到 `~/gst-workspace/tiers`，常用命令是：

```bash
~/gst-workspace/tiers/bin/init --yes
```

`bin/init` 是项目级初始化；`bin/install-codex` 是机器级安装。二者不是一回事。

安装器会：
1. 建用户数据区（Codex 默认 `~/.codex/dev-workflow/`，Claude 环境默认 `~/.claude/dev-workflow/`，可用 `DEV_WORKFLOW_DATA` 覆盖），从模板初始化进化日志
2. 确保项目 `.gitignore` 忽略续行状态文件
3. 检测伴侣 skill（superpowers），缺失则提示降级
4. 检测 codegraph（`code-review-graph`），在则可选注册 MCP（Mode B）

## 日常使用

正常使用时不需要手动运行脚本。新开 Codex 会话后，直接提出开发请求即可，例如：

```text
请用 dev-workflow 帮我实现这个功能：给订单列表增加批量导出
```

或者：

```text
这个 bug 帮我按 dev-workflow 修一下
```

Codex 应该会加载 `dev-workflow`，先输出类似下面的判级行，然后按对应流程执行：

```text
级别 = L2｜理由 = 修改已有逻辑，有回归风险
```

如果命令/skill 不存在，优先检查：

```bash
ls -la ~/.codex/skills/dev-workflow
readlink ~/.codex/skills/dev-workflow
grep -A1 'plugins."dev-workflow@local"' ~/.codex/config.toml
```

## Codex 兼容

Codex 使用 `.codex-plugin/plugin.json` 发现插件。本仓库提供：

- `.codex-plugin/plugin.json`：Codex manifest，声明 `skills`、`hooks` 与插件界面元信息
- `hooks.json`：插件相对路径 hook，避免依赖 Claude 专属 `${CLAUDE_PLUGIN_ROOT}`
- `skills/dev-workflow/SKILL.md`：Codex 可发现的主 skill
- `scripts/lib.sh`：统一解析 `DEV_WORKFLOW_PLUGIN_ROOT`、`CODEX_PLUGIN_ROOT`、`CLAUDE_PLUGIN_ROOT`

Claude Code 侧继续保留 `.claude-plugin/plugin.json`，共享同一份 `skills/`、`hooks.json` 与脚本。

## codegraph 三层降级

| 层级 | 用户环境 | 插件行为 |
|---|---|---|
| 无 codegraph | 未安装 `code-review-graph` | 纯人工判级（决策树 + tie-breaker），**完全可用** |
| Mode A | 装了 + 项目有 `graph.db` | `detect-changes` 判级校验 + TDD 靶向 |
| Mode B | Mode A + 注册了 MCP | 再加事前依赖查询 |

## 用户数据区

插件代码与用户数据**完全分离**——更新插件不会丢失积累数据。

| 数据 | 位置 | 作用域 |
|---|---|---|
| 进化日志 LEARNINGS.md | `${DEV_WORKFLOW_DATA}`；未设置时 Codex 默认 `~/.codex/dev-workflow/`，Claude 默认 `~/.claude/dev-workflow/` | 全局跨项目 |
| 续行状态 | `<repo>/docs/superpowers/.workflow-state.yaml`（gitignore） | per-project |

## 级别速查

| 级别 | 典型场景 | 工作流 |
|---|---|---|
| **L0** 大型改造 | 跨模块重构、架构迁移 | 强制提问 → 范围审视 → 架构验证 → 实现 → QA → 发布 |
| **L1** 大功能 | 新增模块 / 跨文件设计 | brainstorm → spec → plan → TDD → review |
| **L2** 中型迭代 | 改已有逻辑，≥3 文件 | 轻量 spec → TDD → review（可选） |
| **L3** Bug 修复 | 线上回归 / 行为问题 | systematic-debugging → 复现测试 → 修复 |
| **L4** 文案/样式 | 纯 UI 文字 / 样式 | 直接写，无需 spec 或测试 |

## 依赖

**必需：** bash、awk、python3、git

**可选（推荐）：**
- [superpowers](https://github.com/obra/superpowers) — 解锁 L1 的 brainstorm/TDD/plans/review 完整 skill 链
- [code-review-graph](https://github.com/nicobailon/code-review-graph) — 解锁 codegraph 判级校验（Mode A/B）
- [mattpocock/skills](https://github.com/mattpocock/skills) 的 `grill-with-docs` — 内置 `grill-me` 的可选升级：锚定 CONTEXT.md/ADR、边追问边更新文档。装了即优先用。`npx skills@latest add mattpocock/skills`

## 内置 skills

- `dev-workflow` — 工作流路由主 skill
- `grill-me` — L0/L1 设计文档定稿前对其追问一轮、补边界。Vendored from [mattpocock/skills](https://github.com/mattpocock/skills)（MIT © 2026 Matt Pocock，见 `LICENSES/grill-me-MIT.txt`）。

## License

MIT
