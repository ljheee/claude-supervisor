# Stop 异常捕获设计 · stop-anomaly-capture.py

> 背景：walk-tracer rework 全周期（2026-09-06/07，k3 长会话劣化事故）实测暴露三种模型层故障形态，
> 现有监督链（巡检 cron 盘面核验 10 分钟粒度 / watchdog 梯度告警 60 分钟阈值）对部分形态
> 盲区或被掩盖。本方案在 worker 侧加一个机械层 Stop hook，回合结束即检测、即上报、即落证据。
>
> 原则：**不依赖任何模型自觉**（"worker.md 补一条主动上报"已被事故证伪——故障态 worker 无执行者存活）；
> 只读 transcript + stdin，正常回合廉价短路，非受监工项目会话零干扰。

## 一、三种故障形态与特征判据（核心）

判据全部作用于 **transcript 尾部**（Stop hook 的 stdin 含 transcript_path）。
三种形态对 Stop hook 而言都是"正常结束的回合"（stop_reason: end_turn），Hook 照跑——
这是方案成立的事实基础（事故实证：劣化期 stop_hook_summary 一直有记录）。

### 形态 1 · model:error 整回合失败

- **现象**：API 层错误被 harness 包装为正常 assistant 消息（`model: "error"`，
  stop_reason: end_turn），回合正常走完 Stop hook，StopFailure 不触发（监督链盲区）。
  idle 通知附带的 harness 错误文本（"Sorry, I encountered an error processing your request"）
  是该形态唯一主动信号。
- **特征判据**：最后一条 assistant 记录的 `model` 字段 == `"error"`。
- **事故样本**：09-06 23:06 首案；worker transcript 按 model:"error" 统计（09-06 23 时段本地时间 3 次，与首案同时段）。
- **replay 实测（✅ 实证成立）**：判据在 worker 事故 transcript 上命中 3 次
  （本地 23:02:43 / 23:06:21 / 23:55:59），与 supervisor incidents 时间线逐条吻合
  （23:02 idle 错误文本首报 / 23:06 首案 / 23:55 微承诺超期）；健康时段（换模后
  opus 期）双侧零命中零误报。另：SUP transcript 判据 1 零命中——supervisor 劣化
  形态始终不是 model:error，是空回合（见形态 2），两侧劣化形态不对称。
- **盲区互补**：watchdog 对此形态**可能被掩盖**——取决于 supervisor 是否把带错误文本的 idle 通知计入 last_response_ts（协议定义该字段只认 REPORT/STATUS/RESUME/REGISTER 等主动消息，idle 未明文排除，supervisor 执行自觉是变量；当天 watchdog 未部署，此机制未经实测）。Stop hook 是该形态唯一能机械区分"错误终局回合"与"真响应"的信号源，不依赖该变量。

### 形态 2 · 空回合 / 尾部退化（模型空响应返回 "…"）——两个亚型

- **现象**：model 正常但产出退化为空文本或 "…"。worker 进程活着、socket 活着、
  可被 SendMessage 唤醒——但被唤醒的脑子产出为零或半路断掉。
  唤醒通道无修复价值（整夜五次探活实证：每次都能唤醒，问题在被唤醒模型的产出质量）。
- **亚型 2a（整轮空，仅 SUP 侧出现，重度）**：**回合边界**（最后一条**非 tool_result**
  的 user 记录——真实输入 / cron tick / SendMessage——之后；注意 tool_result 在
  transcript 中也是 user 记录，按字面"上一条 user"实现会误切边界）的全部
  assistant 记录加总：零 tool_use 且文本全空或 "…"。
  - ⚠️ 亚型判定：末条为空且整轮（多 assistant 记录：文本→工具调用→收到结果→
    再产出）加总也为空 → full；仅末条为空而前段有实质产出 → tail。误报由健康期
    对照兜底（opus 期 SUP 47 回合 + WORKER 19 回合零误报）。
- **亚型 2b（尾部退化，双侧，轻中度——replay：SUP 8 / WORKER 3）**：回合前段完全正常（thinking /
  文本 / 工具调用俱全），但**末条 assistant 记录零 tool_use 且文本为空或 "…"**，
  stop_reason=end_turn，回合在半路暴毙。解剖样本（12:46:22）：thinking(957字)
  → "Edit #1 落盘" → tool:Edit → tool:SendMessage 回执 → 两个 tool:Edit →
  thinking(2013字) → 末条仅一个 "…"。10:17 / 10:52 两个样本更极端——回合内
  分别干了 6 个和 13 个工具调用，同样以一个 "…" 收尾。
  - **伤害机制**：回合内已执行的工具（Edit/SendMessage）效果已发生，但收尾的
    回执/上报永远发不出去——这就是事故中"worker 干了活但 supervisor 收不到报、
    认知对不上盘面"的直接机制（非认知滞后，是**回合死于收尾之前**）；worker 就此
    idle，须 supervisor 唤醒续命。
  - **与形态 1 同源**：同一 API 劣化的两种显形——重时整回合被包装为 model:error；
  轻时 API 返回合法但退化的补全（仅 "…"），回合看似正常结束。stop_reason 均
  end_turn，StopFailure 均不触发。时间线呈三期病程：23 点 model:error（整回合
  失败）→ 上午尾部退化（干活收不了尾）→ 12:47 后吞调用（连工具调用都发不出）。
- **实现判据（两亚型统一）**：**末条 assistant 记录零 tool_use 且文本为空/"…"**
  即命中（不看回合前段）；整轮空为 severity: full，尾部退化为 severity: tail。
  放宽理由：健康模型几乎不会用单个 "…" 作回合最后一句话，且 opus 健康期实测
  零误报；统一后双侧 2a+2b 共 17 个退化回合全覆盖（SUP 6 full + 8 tail，
  WORKER 3 tail）。
  - ⚠️ 投递规则（replay 实证后的分级规则）：model-error 与 2a（full）单次偶发
    可自行恢复（事故多处单发后自愈），**连击 ≥2 才投递**；**2b（tail）单发即
    投递**——replay 实证 worker 侧 3 个 tail 全部孤立单发（间隔 35min~2h，中间
    夹大量正常回合），连击 ≥2 下一个都不会报，等于不检测；且 tail 回合已产出
    实质工具效果却无收尾上报，危害更隐蔽。计数状态另立文件（见 §三1），
    排除非受监工会话误伤。
- **事故样本**：此前文档记"worker 空回合 98 次"系**消息级误计**（replay 修正：
  按回合聚合后 worker 侧零命中——那些 "…" 是回合内尾巴，回合本身含工具调用或
  协议文本）。真实分布：**SUP 侧亚型 2a 六次**（本地 13:23 / 13:33 / 14:03 /
  15:03 / 15:23 / 15:43，均为巡检 cron tick 劣化期）；**WORKER 侧亚型 2b 三次**
  （10:17 / 10:52 / 12:46，均 k3 期）。尾部退化（末条零 tool_use + 空/"…"，含
  两亚型）合计：WORKER 3 个、SUP 14 个。
- **replay 实测（✅ 判据成立，亚型拆分补全）**：亚型 2a SUP 侧命中 6 次；亚型 2b
  双侧命中 11 次（SUP 8 / WORKER 3）。按分级投递规则（tail 单发即投递），SUP 首个
  tail 12:53:08 即投递——比用户实际发现（15:06）早 133 分钟。健康时段（opus 期）
  双侧零误报。worker 侧的第三形态另有"吞调用"（见形态 3）。
- **盲区互补**：对 Stop hook"看不见"的旧结论只成立于单条判据；读 transcript 尾部
  聚合判即可。watchdog 可查但慢（60 分钟阈值，且同样受"idle 是否刷新静默时钟"变量影响）；
  巡检 cron 可查（find 零写入证据，10 分钟）。

### 形态 3 · 工具调用被吞（叙述了动作但 tool_use 从未进入 transcript）【replay 实测定位】

- **replay 结论（候选 b 淘汰，真实指纹新发现）**：候选判据 b（dangling tool_use）
  在双侧事故 transcript 上**零命中**——预测得到实证，淘汰。真实指纹是反向的：
  **末条 assistant 以文本叙述"已发出/重发/回执"类动作，但整个回合零 tool_use 记录**
  （吞调用：模型产出了解释性文本，工具调用块在 harness/API 层丢失，磁盘从未变）。
- **事故样本（worker，本地）**：12:48:05 "Edit #1.6 发出" / 12:49:40 "Edit #2a
  发出" / 12:54:12 "Edit #2a 重发"——三个回合均零 tool_use。磁盘证据：#2a（§0
  抬头九→十项）**从未落盘**（抬头保持"九项"直到 16:21 supervisor oracle Edit 落地）；
  同期 12:45~12:46 的 Edit #1/#1.5 带 tool_use 且正常落盘（D-10 行在盘）。
  即：先前"Edits 实际在落盘、只是回执被吞"的判断只对了一半——落盘的那几次
  是工具真发出去了；没落盘的那几次是工具根本没发出去。
- **候选判据 c（叙述 + 零 tool_use，与样本一致但低置信）**：回合零 tool_use 且
  末条 assistant 文本含"发出/已发出/重发/已送达/回执/[Send"类动作叙述 → 可疑。
  ⚠️ 文本判据天然脆弱（模型措辞不可依赖，健康回执如"回执确认"也含关键词），
  只能低置信上报（kind: narrated-no-tool），不得作为阻断性判据。
- **主防御不变（实证加强）**：该形态的可靠防线仍是 supervisor 的 oracle 模式
  （盘面为准，不信自报——16:21 oracle Edit 补上 worker 三次"发出"均未落盘的
  #2a 正是实战验证）+ Edit 幂等纪律（12:52 账本协议增补，盲发重试 ×3 无害）。
- **盲区互补**：find 零写入判据对该形态**免疫误杀**（盘上确实在变——但变的是
  早前真发出的那些 Edit，不能证本轮叙述为真）；判据 1/2 均不覆盖此形态，
  oracle 是唯一已验证防线。

## 二、判据汇总表

| 故障形态 | transcript 尾部特征 | Stop hook | 巡检 cron（盘面核验） | watchdog |
|---|---|---|---|---|
| model:error | 末条 assistant `model=="error"` | ✅ 秒级（replay 命中 3/3 零误报） | ⚠️ 慢（10min，靠 idle 错误文本） | ❓ 取决于 supervisor 是否把 idle 计入 last_response_ts（协议未定、实测未覆盖） |
| 空回合/尾部退化（2a 整轮空 / 2b 尾部 "…"） | 末条 assistant：零 tool_use + 空/"…" 文本（整轮聚合为 full，仅末条为 tail；full 连击≥2、tail 单发即投递） | ✅ 秒级（replay：SUP 6+8、WORKER 3；tail 单发 12:53 即投递，早 133min） | 2a ✅ find 零写入（10min）；2b ⚠️ 盘上有写入零写入不触发，靠承诺超期路径（11:14/11:35 incidents 即此） | ⚠️ 慢（60min），同受 idle 计入变量影响 |
| 工具调用被吞 | 末条 assistant 叙述动作（"发出/重发/回执"）但回合零 tool_use | ❓ 候选 c 低置信（replay 3/3 命中，但文本判据脆弱、健康回执含同关键词） | ⚠️ 免疫误杀但证不了叙述为真 | ❌ 盘在动不告警 |

三层防御分工：**Stop hook 管快**（回合级、模型层证据、不依赖 supervisor 健康）；
**巡检 cron 管中**（10 分钟、物理层零写入证据、对吞调用免疫误杀）；**watchdog 管慢和管上层**
（长静默梯度告警 + 盯 supervisor 死亡/劣化通知用户）。单独哪一层都堵不住全部形态
（三种形态在事故中轮番上场），三层拼合才构成完整防御纵深。
（形态 3 的可靠防线是 oracle 模式 + Edit 幂等纪律——replay 实证：worker 三次
"发出"叙述均未落盘，16:21 oracle Edit 补盘闭环；hook 侧候选 c 仅低置信加速项。）

## 三、实施要点（✅ 已实施，2026-09-08）

1. **worker 侧 hook：`hooks/stop-anomaly-capture.py`**（Stop hook）
   - stdin（含 transcript_path + session_id）→ 廉价短路：非受监工项目（resolve_ledger
     零命中）直接 return；正常回合只多一次**有界尾部扫描**（定位最后一条非 tool_result
     的 user 记录后聚合整轮，含 tool_use↔tool_result 配对检查——不是固定"读一行"）。
   - settings 注册（install.sh 用户级，参照 shard-guard.py 文档头部格式）：
     hooks.Stop（matcher 留空，Stop 事件无 matcher 维度）→ `python3 <此文件>`。
   - 判据 1/2 命中 → 复用 worker-stopfailure.py 全部逻辑：resolve_ledger 找分片 →
     UDS 直投 supervisor（sid 寻址，不依赖会话名）→ 落盘 interrupts.jsonl。
   - **前置步骤：真机 replay 验证——已完成（2026-09-07，结论见 §五）**：判据 1
     实证成立（3/3 命中、零误报）；判据 2 实证成立（2a SUP 6、2b SUP 8 +
     WORKER 3；分级投递规则 tail 单发 12:53 即报、早 133min；零误报）；
     候选判据 b 零命中淘汰；
     新发现候选判据 c（形态 3 真实指纹，replay 3/3 命中，低置信可选实现）。
   - 投递消息统一：`WORKER INTERRUPTED (kind: model-error | empty-turn[:full|:tail])`
     （severity 后缀标注亚型）；候选 c 若实现另加 `kind: narrated-no-tool`
     （低置信，supervisor 侧仅作探活触发线索，不作阻断依据）。
   - 空回合连击计数状态：另立文件 `.supervisor/<监工 sid>/anomaly_state.json`
     （**不得复用 watchdog_state.json**——watchdog 的去重梯度也写那个文件，两个写者
     共用一个文件会引入 v3 特意用 fcntl 消灭的竞态）。注：hook 机械写入**监工分片**
     是 interrupts.jsonl 已有的先例支持的例外；模型层仍禁写一切分片（shard-guard
     管的正是模型层的 Write/Edit）。
2. **supervisor 侧协议条款**（_core-supervisor.md）
   - 收到 WORKER INTERRUPTED（任何 kind）→ 置 pending_check（10 分钟短结算）：
     期间收到 worker 实质消息则清空（09-06 23:04 自愈路径语义不变）；无消息则重发
     STATUS CHECK 探活。保底响应时间从 60 分钟缩到 10 分钟。
   - 兼容既有信号：idle 通知附带 harness 错误文本 → 同样置 pending_check 短结算
     （信号通道已被事故证明可用，作为 hook 失效时的兜底）。
3. **worker.md 条款（能活的形式）**
   - 不是"出错后主动上报"（无人执行，已证伪），而是：**被唤醒时（SendMessage/STATUS CHECK
     到达）若发现上文存在 model:error / 空回合记录，第一动作发 WORKER STATUS 报告中断点**
     ——加速恢复，不承担检测职责。
4. **边界（诚实声明）**
   - hook 只能"把病床上的人叫醒医生"，治不了病：三种形态的修复动作不变
     （supervisor 判定后升级用户做 /compact / 换模 / resume）。
   - 独立价值：supervisor 也劣化场景下 interrupts.jsonl 留下持久证据，换模后 supervisor
     resume 一读便知中断史，无需考古 transcript（09-07 当天全靠手工考古）。
   - /compact 恢复效应实测仅 ~25 分钟（12:20→12:48 复发），劣化是 k3 长会话系统性问题，
     hook 不解决根因，只消除检测盲区。
5. **测试**：test_stopfailure.sh 加四个 case（形态 1 / 形态 2 各一个尾部特征样本 +
   连击计数跨回合状态一个 + 短路零干扰 case）；候选判据 c 若实现另加 case
   （叙述+零 tool_use 命中 + 健康回执文本不误报）。
   **实施结果（2026-09-08）**：case 22（model-error 即时投递）/ 23（健康回合零写入 +
   streak 键为空）/ 24+24b（full 连击：首发抑制并记 streak=1、第二发投递）/ 25
   （tail 单发即投递）/ 26（健康回合重置 streak）/ 27（陌生人会话零干扰）——
   65→83 断言全绿（含 worktree git fallback 回归 case 29）。候选判据 c 未实现（维持低置信挂账，主防线 oracle 不变）。

## 四、事实依据索引（事故档案）

- 会话：walk-tracer rework，supervisor a5f150f2（2a→e7），worker 54d21839（ce→1a），
  k3 双会话劣化，/exit + 换模 claude-opus-5 后 2 小时跑完 dev-1~dev-7 全程收工
  （对照实证：故障全部是模型层而非协议层）。
- transcripts：`~/.claude/projects/-Users-lijianhua04-Documents-IdeaProject-walk-tracer/`
  下 a5f150f2-*.jsonl / 54d21839-*.jsonl。
- supervisor 账本：walk-tracer `.supervisor/a5f150f2-*/state.json` incidents 11 条全程故障史
  （23:02/23:54/00:13/11:14/11:35/11:56/11:58/12:16/12:48/12:52/16:21）。
- oracle 模式与 Edit 幂等纪律：12:52 账本原文；盲发重试 ×3 无害落盘实证。
- 监督链盲区结构分析：supervisor 劣化 3.5h（12:54~16:16）无任何协议路径检测；
  watchdog 全程未部署（crontab 无条目，11 次 STALLED 100% 靠巡检 cron 发现）。

## 五、Replay 实测记录（2026-09-07，replay_check.py）

离线判据验证脚本：`replay_check.py`（本仓库根目录，与本文档同批产出）；
数据：双侧事故 transcript 全量 replay（回合切分 = 最后一条非 tool_result 的 user
记录，与 §一判据逐字对齐）。

| 验证项 | 结果 | 细节 |
|---|---|---|
| 判据 1 命中 | ✅ 3/3 | worker：23:02:43 / 23:06:21 / 23:55:59（本地），与 incidents 时间线逐条吻合 |
| 判据 1 误报 | ✅ 零 | opus 健康期（16:16 后）双侧零命中（SUP 47 回合 / WORKER 19 回合） |
| 判据 2 命中（SUP，亚型 2a） | ✅ 6 | 13:23 / 13:33 / 14:03 / 15:03 / 15:23 / 15:43（本地，均为 cron tick 劣化回合） |
| 判据 2 命中（WORKER，亚型 2b） | ✅ 3（尾部判定扩展） | 10:17 / 10:52 / 12:46（本地，回合内 6/13/5 个工具后以单个 "…" 收尾；原始整轮聚合判据下为零——这 3 个回合产生的多条 "…" 消息正是 "98 次"误计的子集） |
| 尾部退化回合总量（末条零 tool_use + 空/"…"） | WORKER 3 / SUP 14 | 统一末条判定的覆盖面 |
| 判据 2 投递规则 | ✅ 有效 | tail 单发即投递：SUP 首个 tail 12:53:08 即投递——比用户实际发现（15:06）早 133 分钟；旧 full-only 连击口径下为 13:33 投递、早 93 分钟。⚠️ 若 tail 也用连击 ≥2：worker 3 个 tail 全孤立，一个都不会报（等于不检测）——分级规则的依据 |
| 判据 2 误报 | ✅ 零 | opus 期双侧零命中（SUP 47 回合 / WORKER 19 回合） |
| 候选判据 b（dangling） | ❌ 淘汰 | 双侧零命中，与预判一致 |
| 候选判据 c（新发现） | 3/3 命中 | 12:48:05 / 12:49:40 / 12:54:12（本地）零 tool_use + 动作叙述；磁盘证据：#2a 从未落盘 |

裁决：判据 1/2 通过 replay 验证，可进入实现；候选 b 淘汰；候选 c 低置信可选实现
（文本判据脆弱，仅作探活线索）。形态 3 的主防线维持 oracle 模式 + Edit 幂等纪律
（16:21 oracle Edit 补盘闭环为实战验证）。
