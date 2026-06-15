# dev-workflow 进化日志（全局，跨项目）

本文件是工作流自主进化的事实源。dev-workflow skill 每次被调用时读取它、按 `category` 计数，
积累到阈值（同 category 的 `pending` ≥ 2）即触发固化提案。由 skill 读写，不靠对话记忆。

## category 词表（记录时只能从这里选，没有合适的才新增一行并说明）

```
判级/行为守卫     给已有接口加守卫/拦截/过滤，定级
判级/schema变更   数据库结构/迁移改动，定级
判级/依赖升级     升级依赖或构建配置，定级
判级/跳转逻辑     改 UI 行为/跳转，L2 vs L3/L4
判级/图风险背离   codegraph 风险分与我判级明显不符
流程/续行体感     .workflow-state.yaml 维护相关
流程/tie-breaker  两级拿不准时的默认走向
```

## 记录格式

```yaml
- date: YYYY-MM-DD
  category: 判级/行为守卫        # 必须取自上方词表
  project: <仓库名>
  note: 一句话写清「我原判 Lx，用户纠正为 Ly，因为…」
  status: pending               # pending（待固化）| folded（已进规则）| dropped（否决）
```

## 进化记录（从这里开始追加）
<!-- 暂无记录 -->
