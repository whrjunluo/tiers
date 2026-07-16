# Small-Fix Fast Path Design

## Goal

让已稳定复现、生产改动不超过 3 个文件的窄交互修复，在不降低 root-cause、TDD 和真实业务验收真实性的前提下，把流程墙钟从不可预测的 6 分钟以上收敛到常见 2–4 分钟、外部评审额外等待硬上限 90 秒。

## Event Reconstruction and Attribution

本次样本先按“发送成功后输入框未清空”的线上 bug 判 L3；用户随后补充“失败消息必须保留并可重试”，这扩展了验收分支，重判 L1 有依据，但目标、页面和根因没有改变。

制度放大器：

- `external_agent.py` 串行调用 reviewer，默认每个 600 秒，两个 reviewer 的墙钟上限是 1200 秒；provider 健康建议最高可增长到每个 3600 秒。
- business 任务的完成门只接受双家族 quorum，一个 reviewer 成功后仍必须同步等待第二个。
- level 变化会使 understanding scope 失效，但 controller 没有证据谱系，L3 root-cause 不能被 L1 requirements 引用复用。
- skill 没有窄改动验证矩阵，也没有说明 business verification 只阻塞 done/交付而不阻塞已测试代码的本地 checkpoint commit。
- skill 没有等待更新节流和用户停止协议。

本次 agent 执行偏差：

- 把重判理解为重跑整套证据，而不是复用已验证根因，只补新增 acceptance/non-goals。
- 对 3 个生产文件同时串行执行页面测试、全量 typecheck/test/lint/build，存在重复覆盖；应按改动映射选择目标测试和一个必要的静态/构建门。
- 没有为窄评审显式设置短 timeout，也没有利用一个已成功 reviewer 降级收尾。
- 每 30 秒输出无新信息状态不是 controller 要求，增加了对话长度和“流程仍在拖”的感知。

## Selected Design

新增显式 `execution.profile: standard | small-fix`。`small-fix` 只能用于同一目标的窄修复：稳定复现、目标 TDD、生产改动不超过 3 个文件，且不新增 API/schema、权限、数据迁移或跨端时序。IM 域本身不排除 fast path；改变消息契约、传输或跨端时序时不符合资格。

### Understanding lineage

requirements 证据可用 `reuses: <root-cause evidence>` 引用同一 task/target 的已通过证据。controller 保存并校验原文件 hash、kind 和稳定 objective hash；新 level 仍必须补本级必需字段，不能拿复用绕过 acceptance/non-goals。

### Review orchestration

`--cross-review` 默认并行。标准 profile 保持严格双家族 quorum，但墙钟由 reviewer timeout 之和变为最大值。`--review-profile small-fix` 在未显式传 timeout 时每个 reviewer 使用 90 秒，并采用 `minimum_successes=1`：第一个有效 reviewer 返回后终止仍在等待的 reviewer，报告 `outcome: degraded`、`quorum: false` 和取消原因。若两个 reviewer 已成功，仍报告严格 quorum。

失败或终止证据统一包含：`review_profile`、`policy`、`outcome`、`created_at`、`finished_at`、`duration_seconds`，以及每个 reviewer 的 `status`、`duration_seconds`、timeout 和 error/result。用户中止产生 `outcome: terminated`，不能被 completion gate 当作通过。

small-fix controller 只接受绑定当前 repository fingerprint、24 小时内、至少一个真实外部 family 成功且 runner 明确标记 degraded-policy pass 的报告。标准 profile 的历史双 quorum JSON 继续有效。

### Verification and delivery

- root-cause 和 Red/Green 不变。
- 验证命令按 changed behavior 映射：目标测试必跑；只增加一个能覆盖类型/构建风险的必要门。全量 test/lint/build 只在共享基础设施、配置或影响图提示扩大时执行。
- business verification 可以与外部只读 review 并行，但必须绑定冻结 diff；未完成时可做本地 checkpoint commit，状态仍停在 `business-verify`，不得声明 done、merge、ship 或 deploy。
- 等待期间只在 provider 成功/失败/超时/取消等状态变化时更新；没有新信息不做 30 秒心跳。用户明确关注速度时直接使用 small-fix；用户要求停止时立即终止 review 并保存 terminated evidence。

## Time Budget

| Segment | Before | Small-fix budget |
|---|---:|---:|
| 判级、根因与证据 | L3→L1 可重复 1–3 分钟 | 复用根因，只补 requirements，20–45 秒 |
| TDD 与验证 | 页面测试 + 全量四连，2–5 分钟 | 目标 Red/Green + 1 个必要门，60–150 秒 |
| codegraph | 可能重复 | 最多一次，15–45 秒或人工降级 |
| business verify | 串行收尾 | 30–90 秒，可与 review 并行 |
| external review | 串行，默认 2×600 秒上限 | 并行；常见首成功 15–60 秒，硬上限 90 秒 |
| 状态与对话 | 30 秒心跳、重复归档 | 仅状态变化，15–30 秒 |

标准 cross-review 的最坏墙钟从约 `sum(timeouts)+overhead` 降为 `max(timeouts)+overhead`。small-fix 的流程目标是常见 2–4 分钟；真实环境不可用时如实停在 business verification，不用更多本地门禁掩盖外部阻塞。

## Compatibility and Non-Goals

- 默认 profile 是 `standard`，旧命令、旧状态和严格 quorum 行为保持兼容。
- 不自动根据文件数切换 profile，避免把 schema/auth/跨端时序改动误判为小修复。
- 不修改 `gst-ai-doctor-console`，不降低真实业务请求验收，不把 built-in checklist 冒充独立 reviewer。
- 不引入第三方 Python/YAML 依赖。
