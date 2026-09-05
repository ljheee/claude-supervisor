# Spec: claude-supervisor v2 — 定时自巡检与对齐漏斗

> 分支：`feat/v2-scheduled-supervision`
> 依据：`claude_cron.md`（同目录，Claude Code 2.1.259 定时任务机制实测记录）+ 2026-09-05 系列讨论
> 状态：已过子代理 CR（10 条全修）+ 作者终审修订，待用户终审

## 1. 背景与问题

v1 的 supervisor 是纯被动守卫：只在被消息/用户输入唤醒时顺带巡检，"supervisor 一定会醒"依赖外部事件碰运气。同时 v1 的对齐流程是被动问答式的：worker 报什么审什么，真问题（沉默假设、边界缺口、隐藏依赖）的挖掘责任全压在执行者视角的 worker 身上。

实测（claude_cron.md）证明 Claude Code 内置调度器可用且语义明确，可将第三层防御从"被动唤醒"升级为"定时醒来"；同时协议可升级为"对齐漏斗"：clarify 挖理解偏差、spec 挖完整性缺口、plan 挖执行风险，真用户只答目标级问题。

## 2. 目标

1. supervisor 定时自巡检（/loop 路线），不再依赖外部事件唤醒。
2. WORKER INTERRUPTED 退避改用 ScheduleWakeup 原生唤醒，消除 Bash sleep 的超时坑与工具占用。
3. 利用 notify_when_idle 宿主级硬信号刷新 worker 活性时钟（idle ≠ 完成，不作督促触发器）。
4. worker 提问分级 + supervisor 三层回答规则，把"监工代理"与"冒名顶替用户"隔开。
5. 三阶段主动质询清单，在 clarify/spec/plan 各自挖掘对应类型的真问题，设两轮收敛上限防拖延。

## 3. 非目标

- 不改变四层防御架构：第一层 StopFailure hook、第二层 STALLED/RESUME、第四层外部 watchdog 全部不动、不降级。
- 不追求 supervisor 宿主死亡的自愈（session-only cron 随宿主死，由第四层兜底——已确认"无可厚非"）。
- 不考虑 cron 被禁用的降级路径（前提建立在有 cron 之上）。
- 不考虑超过 3 天仍未完成目标的长项目场景（7 天 cron 过期远超该边界）。
- 不改 hook 脚本（worker-stopfailure.py）、watchdog.sh、install.sh 的现有逻辑。
- **不做 tick.md 心跳（原始提案之一，显式裁决）**：提案初衷是 worker 每次工具调用后写时间戳供 supervisor 检查活性。裁决：idle 活性信号（回合级宿主硬信号）+ 60 分钟失联判定已覆盖同目的，PostToolUse hook 落盘的粒度增量（工具级 vs 回合级）对 60 分钟阈值无意义，且新增 hook 维护成本。若未来失联阈值需要分钟级精度，再重启此提案。

## 4. 架构定位

```
第一层  StopFailure hook        —— 不变
第二层  协议层 STALLED/RESUME    —— 不变
第三层  supervisor 巡检          —— 被动唤醒 → /loop 10m 定时醒来 + 被动唤醒兜底（本次升级）
第四层  外部 cron watchdog       —— 不变，不可替代
```

新增信号频率谱（自下而上）：

| 频率 | 信号 | 来源 | 性质 |
|---|---|---|---|
| 分钟级 | watchdog 告警 | 外部 cron | 硬 |
| 10 分钟 | 巡检 tick | session-only cron | 硬（宿主调度器） |
| 回合级 | idle 通知 | notify_when_idle | 硬（宿主） |
| 里程碑 | WORKER REPORT | worker 模型 | 软 |

（idle 通知自 v2 起作为 last_response_ts 的硬信号源；失联判定仍以 60 分钟时限为准）

## 5. 功能需求

### F1 定时自巡检（supervisor.md）

启动步骤新增：supervisor 初始化完成后，用 `CronCreate` 创建每 10 分钟的巡检任务。

约束与设计决定：

- **必须 session-only（durable=false，默认值）**：durable 会带来 worker 同目录接管执行巡检 prompt 的污染风险（claude_cron.md §三）。执行者永远只有 supervisor 自己。
- **幂等【P1-4 修订】**：创建前先 `CronList` 查重（prompt 含监工巡检标识的已存在任务即跳过，不重建）——/supervisor 协议重注入是既定的漂移恢复手段，重跑启动步骤不得产生双 cron。
- 巡检 prompt 内容 = 现有巡检三步（失联判定 / pending_check 结算 / 中断补课）+ CronList 自查（任务消失则重建——crons 会自动过期，重建是例行动作不是异常）+ 显式声明"这是持久例行动作，除非收到 CronDelete 收尾指令否则每轮照常执行"（防 /loop 动态模式的 noop 自主熔断语义迁移到固定 cron，见 claude_cron.md §五）。
- **noop 纪律**：无事项时只输出一行"巡检正常，无待办"，不发消息不做长报告。每次 tick 都消耗 supervisor 上下文，长篇例行输出会加速协议淡化。
- cron 触发"等当前回合结束才注入"（⚠️ 二进制证据未直接观测），不违反被动守卫（不插队正在进行的审查）。
- **被动守卫红线同步修订【P1-1 修订】**：行为红线"不在没有 worker 通知时主动轮询"改写为"定时巡检 cron 的检查是唯一例外；tick 无事时零消息零长输出"。
- 全部 worker phase=done 时：整体置 done，用 CronDelete 清掉巡检 cron，再向用户做总结报告。
- 协议不硬编码过期天数等易变参数，一律以现场 CronList 为准。

### F2 ScheduleWakeup 退避（supervisor.md）

收到 WORKER INTERRUPTED 的处理流程中，`sleep 300`（Bash 工具）替换为 `ScheduleWakeup(delaySeconds=300, reason=..., prompt=...)`，**流程结构同步重排【P1-3 修订】**：

- **arm 之前**完成本回合内必须落账的全部动作：记 incidents、追加 acknowledged.jsonl、置 pending_check——ScheduleWakeup arm 后本回合即结束，这些动作在唤醒后无法补。
- **唤醒动作整体移入唤醒 prompt**：prompt 自包含完整指令（"该 worker 因 429 中断于 Phase N，立即用 SendMessage 唤醒它继续执行 Phase N，若上下文丢失先用 git log/git status 对齐；10 分钟内无回应按 pending_check 结算重试或升级"），原流程第 3、4 步中"退避结束后"的时序表述删除。
- 消除 Bash 默认 2 分钟超时打断退避的坑位提示（timeout 参数 ≥360000ms 的 workaround 整段删除）。
- 消除退避期间占用一个工具调用回合的问题。
- api-error 类中断退避 60 秒（ScheduleWakeup 下限即 60s，恰好可用）。
- 多 worker 错峰仍保留：每个额外中断 +60s（360/420...，上限 3600s 内）。
- 保留说明：ScheduleWakeup 的 delaySeconds 被运行时夹在 [60, 3600]。

### F3 idle 活性信号（supervisor.md + worker.md）【P0-1 修订：督促触发器→活性信号】

- supervisor 每次 SendMessage 给 worker 时附带 notify_when_idle 订阅（随消息附带，非永久）。
- **idle 通知唯一职责：刷新该 worker 的 `last_response_ts`**。它是宿主级硬证据（进程活着、回合正常结束），是失联判定的最佳输入信号；不触发任何新的督促路径。
- 是否督促仍走既有机制：60 分钟失联判定 + STATUS CHECK + pending_check 结算，一套逻辑不双轨。
- 语义边界：idle ≠ 完成。完成判定永远以 WORKER REPORT 为准；idle 只证明"活着"。
- 禁止：不得因"idle 到达但无对应 REPORT"而发督促消息——worker 协议本来就是不干完里程碑不上报，长 Phase 中间每回合结束都会 idle，按 idle 督促会按回合频率轰炸正在干活的 worker，违反被动守卫。
- ⚠️ 假设标注："SendMessage 附带 notify_when_idle 订阅"的具体机制未实测（仅有二进制逆向证据），列入 dev-5 挂账实测；若实测不可用，本 F 项整体降级为纯文档说明，不影响其他 F 项。

### F4 提问分级与三层回答（worker.md + supervisor.md）

worker.md 的提问协议升级：向 supervisor 发送待确认问题时，每个问题必须标注分级字段：

```
级别: goal内   —— goal 原文/scope/已 APPROVE 产出物可直接推导
级别: 监工职权 —— 质量标准、Phase 划分、验收口径
级别: 需用户   —— 改变目标本身：需求取舍、优先级、范围增减
```

supervisor.md 收到问题包的三分支：

1. goal内：直接回答，不打扰用户。
2. 监工职权：裁决并回答，决策记入 state.json 新增 `decisions` 字段，总结报告时向用户披露。
3. 需用户：汇总后在自己终端问真用户，拿到答案回传。攒批提问，避免挤牙膏式打扰。

红线不变：破坏性操作的用户授权请求不许转发给 supervisor 代答（worker 直接问用户）。

### F5 三阶段主动质询（supervisor.md）

**clarify——对抗式挖掘**：worker 交"理解+假设+待确认"后，supervisor 先质询再转发用户：

- goal 里每个关键动词/名词，要求 worker 显式给出自己的理解。
- 专找**沉默假设**：worker 没写成"假设"的默认选择（错误处理、边界输入、并发、性能预期、数据量级）。
- 反向问"这个目标里什么没做算失败"——显式化验收标准。
- 挖掘产出合并进待确认清单，一次性打包问用户（其中按 F4 分级，goal 内的直接答）。

**spec——场景拷问**：审查不看"写了什么"更看"缺了什么"：

- 边界条件：空输入、超大数据、并发冲突。
- 错误路径：每条正常流程对应的失败分支。
- 非功能需求：性能/容量没写的，回炉补答案或升级为待确认问题。

**plan——依赖与反证**：

- 每个 phase 的 DoD 必须**可客观验证**（"测试全绿 + XX 可演示"合格，"基本完成"不合格）。
- phase 间隐藏耦合检查：B 是否假设了 A 的内部实现细节。
- pre-mortem：让 worker 回答"假设最终交付失败，最可能死在哪一步"。

**共同纪律**：质询产出按 F4 分层即刻分流；**每阶段质询最多两轮**，两轮后强制收敛（答案进 spec/plan）或升级用户，防"完美澄清"变不开工借口。**质询轮计数器与 Loop Guard（3 次 REFINE）是独立计数器，互不累计**【P2-1 修订】：质询是澄清行为不产生 REFINE verdict，不推进 Loop Guard 计数。

### F6 文档同步

- README.md：中断处理表格第三行改为"定时自巡检（/loop 每 10 分钟 cron）+ 被动唤醒兜底"、watchdog 节前的四层描述同步；新增"定时自巡检"小节（CronCreate session-only + CronList 自查重建 + noop 纪律）。【P1-2 修订：README 实际无"四层防御"独立节，锚点为中断表格与 watchdog 节】
- DESIGN.md：新增"定时自巡检与对齐漏斗（v2）"节（session-only 选择理由=worker 接管污染、ScheduleWakeup 语义与流程重排、noop 纪律、idle 活性信号、三层回答防火墙、三阶段质询）；**修订既有章节的过时结论**：§2.3/§2.4（notify_when_idle 从"明确不用"改为"v2 起用作活性信号，不用作督促触发器"）、§3（"触发器是消息不是轮询"补定时巡检例外）、§4.3、"无法定时醒来"等 v1 表述。
- claude_cron.md **本次纳入仓库**（cp 至 specs/2026-09-05-scheduled-supervision/claude_cron.md），DESIGN/README 引用仓内路径【P2-4 修订】。

## 6. 验收标准（DoD）

1. supervisor.md / worker.md 包含 F1–F5 全部协议条款，语义无冲突、无残留旧机制描述（如 Bash sleep 退避的 timeout 坑位提示）。
2. 现有两套回归测试（test_stopfailure.sh、test_watchdog.sh）零改动通过——本次升级不触碰任何被测代码路径。
3. README/DESIGN 与新协议一致，无 v1 残留表述。
4. 协议文本自检：每条新指令满足"命令式、可执行、有失败分支"；质询清单每条可被 LLM 直接执行（无"适当挖掘"这类模糊措辞）。
5. 人工评审通过（用户 CR）。

## 7. 风险

| 风险 | 对冲 |
|---|---|
| 协议膨胀导致遵循度下降（supervisor.md 预计增至约 240 行） | 新条款合并进现有节不加新节；质询块每条≤1 行命令句（dev-2 DoD 可查）【P2-5】 |
| cron 7 天过期后静默消失 | 巡检 prompt 内置 CronList 自查+重建（F1） |
| /supervisor 重注入产生双 cron | 启动步骤先 CronList 查重（F1 幂等）【P1-4】 |
| notify_when_idle 订阅机制不可用（未实测假设） | F3 已降级为纯增益信号，不可用则整体删除不伤主链路【P2-3】 |
| idle 消息消耗 supervisor 上下文（worker 每回合一条注入）【终审新增】 | 订阅机制若实测确认，可评估仅长 phase 订阅；接受度不适再回退 F3 |
| ScheduleWakeup 唤醒 prompt 丢上下文 | prompt 自包含 + arm 前落账（F2）【P1-3】 |
| 质询两轮上限被模型忽略 | 上限写成硬规则并挂 Loop Guard 同款措辞 |
| 协议自相矛盾（被动守卫 vs 定时巡检） | 红线同步修订为"定时巡检是唯一例外"【P1-1】 |
