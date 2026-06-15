# dev-workflow plugin

分级开发工作流路由 Claude Code Plugin，实现 L0–L4 自动判级、跨 session 续行与跨项目自主进化。

## 简介

根据需求复杂度自动路由到对应工作流（L0 大型改造 → L4 文案/样式），减少过度设计与漏测风险。

## 安装

```bash
bin/init
```

执行后将 plugin 注册到当前项目的 `.claude/` 配置中，并完成依赖检查。

## 三层 codegraph 降级说明

codegraph 判级集成支持三层降级策略，确保在不同环境下均可运行。

- **第一层（完整模式）**：调用 `code-review-graph` 工具进行精确依赖分析，输出跨模块影响评分。
- **第二层（轻量模式）**：使用 `git diff --stat` + `awk` 统计变更文件数与模块分布，近似估算影响范围。
- **第三层（兜底模式）**：纯文本启发式判断，仅依赖 bash，无任何外部工具依赖。

## 用户数据区位置

插件的用户数据（状态、跨 session 上下文）存储在：

```
~/.claude/dev-workflow/
```

项目级状态存储在项目根目录下的 `.claude/dev-workflow/` 中。

## 依赖

### 必需

- `bash` ≥ 3.2
- `awk`
- `git`

### 可选

- `python3` — 用于高级判级 hook
- `code-review-graph` — 启用 codegraph 精确判级（第一层）
