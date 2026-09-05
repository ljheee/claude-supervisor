# Plan: claude-supervisor v2 — 定时自巡检与对齐漏斗

> 依据：`spec.md`（同目录）
> 原则：本次升级**只改协议文本与文档**，零代码改动（hook/watchdog/install 不动），两套回归测试零改动必须全绿。

## Phase 划分总览

| Phase | 内容 | 改动文件 | 依赖 |
|---|---|---|---|
| dev-1 | supervisor.md：定时自巡检 + ScheduleWakeup 退避 | commands/supervisor.md | 无 |
| dev-2 | supervisor.md：idle 活性信号 + 三层回答 + 三阶段质询 | commands/supervisor.md | dev-1 |
| dev-3 | worker.md：提问分级 + idle 协同说明 | commands/worker.md | 无（与 dev-1/2 并行安全，但为评审串行） |
| dev-4 | README.md + DESIGN.md 同步 | README.md, DESIGN.md | dev-1~3 |
| dev-5 | 回归验证 + 自检 + commit | 全部 | dev-1~4 |

每 Phase 完成即 commit（`worker: claude-supervisor, phase: dev-N` 格式由执行者按仓库习惯调整），commit 前跑该 Phase 的 DoD 验证。

---

## dev-1 supervisor.md：定时自巡检 + ScheduleWakeup 退避

对应 spec F1 + F2。

### 步骤

1. **启动步骤**新增第 6 条（现第 6 条顺延为第 7 条）：初始化完成后创建巡检 cron。措辞要点：
   - **先 `CronList` 查重**：已存在 prompt 含"监工巡检"标识的任务则跳过创建（幂等，防 /supervisor 重注入产生双 cron）【P1-4】。
   - 不存在时 `CronCreate(cron='*/10 * * * *', prompt=<巡检指令>, recurring=true)`，**不传 durable**（默认 session-only，写明理由一句话：durable 会被同目录其他会话接管执行，巡检必须只属于 supervisor）。
   - 巡检指令自包含：① CronList 自查，任务消失（自动过期）则立即重建——例行动作非异常，且这是持久例行动作，无 CronDelete 收尾指令每轮照常执行；② 执行巡检三步（失联判定 / pending_check 结算 / 中断补课）；③ 无事项时只输出一行"巡检正常，无待办"，不发消息不长篇报告（noop 纪律）。
2. **第三层防御**段落改写：标题改为"你自己的巡检 + 定时自巡检 cron"；首句改为"启动时你已创建每 10 分钟的巡检 cron（见启动步骤第 6 步）；即使 cron 失效，你仍在每次被唤醒时顺带执行同样的巡检三步"。巡检三步正文不动。
3. **行为红线同步修订**【P1-1】："不在没有 worker 通知时主动轮询打扰（被动守卫）"改为"定时巡检 cron 的周期性检查是唯一例外（tick 无事时零消息零长输出）；除此之外不在没有 worker 通知时主动打扰"。核心原则第 2 条"平时你保持静默等待"同步补"（定时巡检的 noop 输出除外）"。
4. **WORKER INTERRUPTED 处理流程整体重排**【P1-3，不只是替换 sleep】：现流程"1 记 incidents → 2 退避 sleep → 3 退避结束后唤醒 → 4 确认闭环+pending_check"改为：
   1. 记 incidents。
   2. **本回合内立即落账**：追加 acknowledged.jsonl、置 pending_check——ScheduleWakeup arm 后本回合即结束，这些动作在唤醒后无法补。
   3. **arm**：调用 `ScheduleWakeup(delaySeconds=300, reason="中断退避：worker X (429限流)", prompt=<自包含唤醒指令>)`。
   4. 唤醒 prompt 内容（原第 3/4 步的时序动作全部移入）："worker X 因 429 中断于 Phase N，立即用 SendMessage 唤醒它继续执行 Phase N，若上下文丢失先用 git log/git status 对齐；唤醒后 10 分钟内无回应按 pending_check 结算重试或升级"。
   5. 删除 sleep 300、Bash timeout ≥360000ms 的整段坑位说明。
   补充两点说明：delaySeconds 运行时夹在 [60,3600]；多 worker 错峰规则不变（每额外 +60s）。api-error 类退避 60s（恰为下限）。
5. 同流程的"配合 watchdog 的 cron 定时器"措辞更新为"定时巡检 cron 保证你最多 10 分钟醒一次；外部 watchdog 兜底你宿主死亡的场景"。
6. **dev-N 状态机**第 4 步：全部 done 时在总结报告前插入 CronDelete 清巡检 cron。

### DoD

- [ ] grep supervisor.md 无 `sleep 300`、无 `360000`、无 `timeout 参数` 字样
- [ ] 启动步骤含 CronList 查重（幂等）且含 CronCreate 不传 durable，附理由
- [ ] 巡检指令含 CronList 自查重建 + noop 纪律两要素
- [ ] 中断流程为四步重排结构：落账在前、arm 在后、唤醒指令全部内嵌于 prompt
- [ ] 行为红线含"定时巡检是唯一例外"措辞，核心原则"静默等待"句同步修订
- [ ] 收尾流程含 CronDelete

---

## dev-2 supervisor.md：idle 活性信号 + 三层回答 + 三阶段质询

对应 spec F3（修订后：活性信号非督促触发器）+ F4（supervisor 侧）+ F5。

### 步骤

1. **idle 活性信号**【P0-1 修订后语义】：在"中断与失联处理"章节置于 WORKER STATUS 小节之后新增小节：
   - 每次 SendMessage 给 worker 时附带 notify_when_idle 订阅。
   - **收到 idle 通知的唯一动作：刷新该 worker 的 last_response_ts**（宿主级硬证据：进程活着、回合正常结束）。
   - 禁止条款显式写入：不得因 idle 无对应 REPORT 而发督促消息（worker 协议本就是不干完里程碑不上报，长 Phase 中间每回合都 idle，按 idle 督促会轰炸正在干活的 worker，违反被动守卫）。
   - idle ≠ 完成，完成判定永远以 WORKER REPORT 为准。
   - ⚠️ 标注：notify_when_idle 订阅机制未实测，若实际不可用本节自动失效，不影响其他条款。
2. **三层回答规则**：在"OODA 循环"或 clarify 阶段相关位置新增小节"收到 worker 提问包（级别标注）的处理"：
   - goal内→直接答；监工职权→裁决并记入 state.json（新增 decisions 字段：`[{"ts","question","decision"}]`，schema 段同步加）→总结报告披露；需用户→攒批问真用户后回传。
   - 红线重申：破坏性操作授权不许代答。
3. **三阶段质询**：改写阶段状态机的 Phase 0/1/2 三节，**质询块合并进现有节内不加新节，每条指令≤一行命令句**【P2-5】：
   - clarify：新增"对抗式挖掘"指令块（关键名词显式理解 / 沉默假设清单 / "什么没做算失败"反向问 / 挖掘产出按三层分流后打包问用户）。
   - spec：新增"场景拷问"指令块（边界条件 / 错误路径 / 非功能缺口，缺口回炉或升级）。
   - plan：新增"依赖与反证"指令块（DoD 可客观验证 / 隐藏耦合 / pre-mortem 一问）。
   - 共同纪律：**每阶段质询最多两轮**，两轮后强制收敛或升级（措辞对齐 Loop Guard 的硬规则风格）；**质询计数器与 Loop Guard 独立，互不累计**【P2-1】。
4. state.json schema 段：新增顶层 `decisions` 字段定义。

### DoD

- [ ] idle 小节唯一动作是刷新 last_response_ts，含显式禁止督促条款
- [ ] 三层回答各分支有明确去向，监工职权分支落 decisions 字段（schema 已同步）
- [ ] clarify/spec/plan 三节各含质询块，每条≤1 行命令句，无新增加节约，无"适当/尽量"类模糊词
- [ ] 两轮上限为硬规则，与 Loop Guard 独立声明存在
- [ ] supervisor.md 增量≤80 行（wc -l 前后对比）【P2-5】

---

## dev-3 worker.md：提问分级 + idle 协同

对应 spec F4（worker 侧）+ F3（worker 侧说明）。

### 步骤

1. **提问协议升级**：将现有"需求层面的疑问打包发给 Supervisor"条款扩展为结构化格式：

   ```
   WORKER QUESTIONS
   Phase: <当前 phase>
   1. <问题> 
      级别: goal内|监工职权|需用户
      我的倾向: <若有>
   2. ...
   ```
   附分级定义三行（与 supervisor.md 完全同文案，避免两份协议漂移）。级别拿不准时标"需用户"，宁高勿低。
2. **idle 说明**：在"上报协议"节补一句：你每轮结束进入空闲时宿主可能向 supervisor 发 idle 通知，这是正常机制不是负担；但**完成通知永远以你主动发的 WORKER REPORT 为准**，不要依赖 idle 代替上报。
3. 红线节补一句：破坏性操作授权直接问用户，不许放进 QUESTIONS 包让 supervisor 代答。

### DoD

- [ ] WORKER QUESTIONS 模板含级别字段与分级定义，与 supervisor.md 分级文案逐字一致
- [ ] idle 说明明确"不代替 REPORT"
- [ ] 红线含破坏性操作条款
- [ ] 全文无 v1 残留表述：注意"把问题留在本终端等用户"在现有协议里是应保留的否定式纪律（"不要直接把问题留在本终端等用户"），验证时排除否定式命中，只查肯定式残留（如"问题可留在本终端等用户"）【P2-2 落地】

---

## dev-4 README + DESIGN 同步

对应 spec F6。

### 步骤

1. **README.md**【P1-2 修订：实际无"四层防御"独立节，锚点为中断表格 + watchdog 节】：
   - 中断处理四层列表第 3 项改为"定时自巡检（/loop 每 10 分钟 cron，session-only）+ 被动唤醒兜底"；第 1 项补 ScheduleWakeup 退避一句。
   - 新增"定时自巡检"小节：机制一句话（CronCreate session-only + CronList 自查重建 + noop 纪律）+ 依据链接 specs/2026-09-05-scheduled-supervision/claude_cron.md（仓内路径）。
   - "命令说明"与"注意"节检查有无过时表述。
2. **DESIGN.md**【P1-2 修订：必须同步修订既有过时结论，不能只新增】：
   - 新增"定时自巡检与对齐漏斗（v2）"节：session-only 选择理由（worker 接管污染，引 claude_cron.md §三）、ScheduleWakeup 语义与流程重排（arm 前落账）、noop 纪律动机（上下文膨胀→协议淡化）、idle 活性信号（硬软信号分层）、三层回答防火墙（防 LLM 互相说服的漂移放大器）、三阶段质询（执行者视角盲区）。
   - **修订既有章节**：§2.3/§2.4 notify_when_idle 从"明确不用"改为"v2 起用作活性信号，不用作督促触发器"；§3"触发器是消息不是轮询"补定时巡检例外；§4.3 相关表述；grep 清除"无法定时醒来""不会定时醒来"残留（DESIGN.md 行 206 的 sleep 300 坑位说明同步替换）。
   - 已知边界节：补充"cron 调度器寄生宿主进程，supervisor 死则巡检死，第四层不降级"。
   - 信号频率谱表（spec §4）纳入。
3. `cp ../claude_cron.md specs/2026-09-05-scheduled-supervision/claude_cron.md`【P2-4】。

### DoD

- [ ] README 中断表格第三层描述与 supervisor.md 一致
- [ ] DESIGN 新节六要素齐全（session-only 理由/ScheduleWakeup 重排/noop/idle 活性信号/三层防火墙/三阶段质询）
- [ ] DESIGN §2.3/§2.4/§3/§4.3 的 notify_when_idle 与轮询相关过时结论已修订（无"明确不用"残留）
- [ ] 已知边界含 cron 寄生条目
- [ ] claude_cron.md 已在 specs/ 目录内，README/DESIGN 引用仓内路径
- [ ] 全文 grep 无 `sleep 300`、`无法定时醒来`、`不会定时醒来` 残留

---

## dev-5 回归验证 + 自检 + 收尾

对应 spec DoD 全项。

### 步骤

1. 跑 `bash test_stopfailure.sh` 与 `bash test_watchdog.sh`，必须零改动全绿（本次未触碰被测代码，任何失败都说明改坏了别的东西）。
2. spec §6 DoD 逐条勾验（grep 清单 + 通读）。
3. plan 自检：F1–F6 在 plan 中的映射表核对（F1→dev-1、F2→dev-1、F3→dev-2/3、F4→dev-2/3、F5→dev-2、F6→dev-4）。
4. 挂账实测清单更新（写入 spec 附录或 DESIGN 挂账节）：① notify_when_idle 订阅机制实测；② 伪造 WORKER INTERRUPTED 注入真 supervisor 观察 ScheduleWakeup 退避全流程；③ SendMessage 唤醒 StopFailure 状态 worker 的可达性。
5. commit（单 commit 或按 Phase 已 commit 则最后收尾 commit）。

### DoD

- [ ] 两套回归测试全绿，零改动
- [ ] spec §6 全部 5 项勾验通过
- [ ] F1–F6 映射核对无遗漏
- [ ] 分支上工作树干净，全部已提交

---

## 明确不做（本次）

- 不改 hooks/worker-stopfailure.py、watchdog.sh、install.sh、两套测试脚本
- 不做 durable cron / 接管容灾（spec §3 非目标）
- 不做 idle 督促闭环（P0-1 裁定：降级为活性信号，督促走既有 60 分钟失联判定）
- 不做端到端两真会话联调实测（挂账项，另行安排）
