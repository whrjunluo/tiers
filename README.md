# dev-workflow

分级开发工作流路由 Claude Code Plugin。根据需求复杂度（L0–L4）自动路由到对应工作流，减少判级歧义、漏测风险和跨 session 进度丢失。

## 功能

- **分级决策树**（L0 大型改造 → L4 文案/样式）+ 判级加固（显式判级输出 + tie-breaker + 边界表）
- **跨 session 续行**：per-project 状态文件，脚本独占读写
- **跨项目自主进化**：纠正积累 → 阈值提案 → 人工放行固化规则
- **codegraph 判级集成**：三层优雅降级

## 安装

启用插件后，在项目根目录运行：

```bash
${CLAUDE_PLUGIN_ROOT}/bin/init [--repo <path>] [--yes]
```

安装器会：
1. 建用户数据区（`~/.claude/dev-workflow/`），从模板初始化进化日志
2. 确保项目 `.gitignore` 忽略续行状态文件
3. 检测伴侣 skill（superpowers），缺失则提示降级
4. 检测 codegraph（`code-review-graph`），在则可选注册 MCP（Mode B）

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
| 进化日志 LEARNINGS.md | `${DEV_WORKFLOW_DATA:-~/.claude/dev-workflow}/` | 全局跨项目 |
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

## License

MIT
