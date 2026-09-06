# Plan: claude-supervisor v3 多 Supervisor 并存实施

> 依据：`spec.md`（同目录）
> 原则：core 协议语义零弱化（账本路径换根 + 新增局部条款：名称固定/sid 获取/resume 恢复/registry 四命令/cron 标识）；hook/watchdog 首次进入改动面（v3 spec 明确扩边界），每处改动配回归用例；全部新机制先实测后依赖（dev-0 沿用 rework 的前置实测纪律，八项已闭环）。

## Phase 划分总览

| Phase | 内容 | 改动文件 | 依赖 |
|---|---|---|---|
| dev-0 | 前置实测 ×8：机制假设逐项验证（含 hook 化两项补测） | 无产物（实测记录写回本 plan） | 无 |
| dev-1 | core 协议改造（分片账本 + registry 四命令三时机 + cron 标识 + sid 获取注入行化） | commands/_core-supervisor.md | dev-0 |
| dev-2 | worker.md 发现改造（自报 sid + registry 四分支 + 红线精确化） | commands/worker.md | dev-0 |
| dev-3 | hook 层改造（SessionStart 注入器 + PreToolUse 守卫 + StopFailure 多分片解析 + worktree） | hooks/, test_stopfailure.sh | dev-0 |
| dev-4 | watchdog 分片适配 | watchdog.sh, test_watchdog.sh | dev-0 |
| dev-5 | install.sh + README/DESIGN 同步 | install.sh, README.md, DESIGN.md | dev-1~4 |
| dev-6 | 回归 + 双 supervisor 冒烟实测 + 收尾 | 全部 | dev-0~5 |

每 Phase 完成即 commit（沿用 `worker: claude-supervisor, phase: dev-N` 习惯格式），commit 前跑该 Phase 的 DoD 验证。

---

## dev-0 前置实测（机制假设验证）

不做未实测机制的关键路径依赖。八项独立，任一失败只影响对应设计决策，不阻塞其他项。

### 实测项

1. **CronList 跨会话可见性**（F2 cron 查重修复的前提）：起两个 Claude Code 会话，A 建 cron 后 B CronList——B 能否看到 A 的任务？prompt 内容是否完整可见？（查重键形态已定案完整 UUID，本项只回答可见性与归属信息有无。）
2. **SendMessage 寻址机制**（F3 路由前提）：两个会话并存，验证 SendMessage 的可用寻址键（原计划按 session_id，实测推翻——回炉为名称寻址验证）。
3. **worktree 下 hook 的 cwd 与 git 定位**（F4 前提）：linked worktree 中跑 `git rev-parse --git-common-dir`，确认输出主工作区 gitdir 且可推导主工作区根；确认 hook 在 worktree 中触发时的工作目录就是 worker cwd。
4. **hook stdin 的 session_id 可用性**（F4 分片选择的身份来源）【已实测通过，2026-09-06】：探针 hook（项目级 settings.json，Stop 事件 cat stdin 落盘）+ `claude -p` 实测——stdin JSON 确含 `session_id` 字段，36 位 UUID 格式，与 transcript_path 首行 sessionId 及 projects 目录名三方一致。额外可用字段：`prompt_id`（可作 worker 回合标识）、`cwd`、`transcript_path`。F4 身份源定案：hook stdin session_id。
5. **flock 可用性**（F1 前提）：macOS 无原生 /usr/bin/flock（CR 实测确认，仅 shlock）——定案方案已改为 registry.py 助手脚本（python fcntl），本项实测 registry.py 原型：fcntl 持锁读-改-写 + 锁超时语义 + 并发首建（两进程同时 register 无丢失/重复）；四个子命令（register/heartbeat/unregister/mark-stale，作者终审补充）逐一验证。
6. **resume 保 sid 不变性**（分片键基石假设，CR P1-1）：起一个会话记下 ListAgents 中的 session_id → `claude --resume <sid>` 重开 → ListAgents 再比对——sid 不变则分片键成立；顺带验证 idle 存活会话在 ListAgents 的可见性（stale 判定“可达”语义依赖它）。若 sid 会变，分片键方案回炉重设计。
7. **SessionStart hook stdout 注入上下文**（sid 获取 hook 化的前提）：项目级探针 hook 输出含 session_id 的一行 → `claude -p` 问会话能否复述——能注入则 supervisor/worker 双方的 sid 获取可改为机械注入，替代扫 sessions 注册表；顺带验证 resume 时 SessionStart 是否再触发（resume 恢复流程机械触发的前提）。
8. **PreToolUse exit 2 拦截 + stderr 反馈**（分片键守卫的前提）：PreToolUse 探针对特定路径 Write 返回 exit 2 + stderr → 验证工具调用被拦截、stderr 内容能否反馈给模型——两项都成立则“LLM 选错 sid 写错分片”可机械阻断。

### 实测记录（2026-09-06，八项全部闭环）

1. **CronList 跨会话可见性：不跨会话可见**。终端 B 的 CronList 显示 No scheduled jobs（A 的 session-only 任务对 B 不可见）——多 supervisor 巡检天然隔离，互不吞并的风险实测不存在；cron 查重键的职责收窄为防同会话协议重注入（UUID 标识保留但理由更新）。
2. **SendMessage 寻址：只认会话名称**。UUID 形态与 6 位短 ID 均返回 "No agent named ... is reachable"（两轮对照确证）；名称双向寻址成功（test-97 ↔ test-98 各拿到 msg_id）。**spec F3 的"按 session_id 寻址"不成立，回炉为名称寻址 + 唯一性管理**。
3. **worktree git 定位：通过**。`git rev-parse --git-common-dir` 输出主工作区 .git，取父目录即主工作区根，其下 .supervisor/ 可达；worktree 自身目录无 .supervisor/（特判必要且充分）。
4. **hook stdin session_id：通过**（子代理实测）。stdin JSON 含 session_id（36 位 UUID，与 transcript 首行及 projects 目录名三方一致）；额外可用：prompt_id/cwd/transcript_path。
5. **registry.py 原型：通过**。四子命令语义全验证（幂等 upsert/心跳/stale/注销/错误退出码 2）；并发首建竞态：两进程同时 register，fcntl 锁串行化，无丢失无重复。
6. **resume 保 sid：通过，但会话名重分配**。`claude --resume <uuid>` 成功恢复同一 UUID 会话（sid 持久）；**会话名从 test-98 变为 test-34、短 ID 同变**——会话名是进程生命周期属性，不是持久身份。**推论：supervisor resume 后 worker 手里的旧名字立即失效，必须写恢复流程**。另实测：当前版本 ListAgents **不输出 36 位 UUID**（仅名字+短 ID+状态），v2 存量条款“从 ListAgents 推导 sessionId”失效，sid 获取路径改为扫 `~/.claude/sessions/` 注册表按名字匹配取 sessionId（hook pass-2 同源）。
7. **SessionStart stdout 注入：通过**（2026-09-04 补测）。探针 hook（项目级 settings.json）stdin JSON 含 session_id/source/cwd/hook_event_name/transcript_path 五字段；stdout 输出一行标记，`claude -p` 会话能逐字复述该行（含注入的 36 位 UUID）；**resume 场景 SessionStart 再触发**（source=resume），sid 与原会话一致（分片键假设二次佐证）。**定案：sid 获取可 hook 化**——SessionStart 注入为主、sessions 注册表扫描降级为 fallback；worker 可开局即知自身 sid 并写进 WORKER REGISTER（supervisor 侧免扫）；resume 恢复流程可机械触发（source=resume 时注入核对提示）。
8. **PreToolUse 拦截反馈：通过**（2026-09-04 补测）。exit 2 + stderr 拒绝特定路径的 Write——文件确认未创建（拦截真生效），且模型能逐字复述 stderr 中 DENIED_BY_GUARD 拒绝信息（含守卫提供的正确分片键提示）。**定案：分片键守卫可 hook 化**——“LLM 选错 sid 写错分片”可用 dumb 守卫机械阻断，stderr 可作纠错信道。

### DoD

- [x] 八项实测结论已回填（含两项推翻设计假设的发现：SendMessage 名称寻址、ListAgents 无 UUID；两项 hook 化可行性坐实：SessionStart 注入、PreToolUse 拦截反馈）
- [x] registry.py 原型锁语义定案；resume sid 结论定案（成立，附名字重分配的补偿设计）
- [x] 实测产生的临时会话/文件已清理（测试会话已退出，/tmp 产物已删）
- [x] spec 实测驱动修订已落地（F1/F2/F3 三处 + 复审补修：F4 归档多命中逻辑矛盾、F1 活性检查改按 name、零回归允许项扩六类）

---

## dev-1 core 协议改造（F2）

### 步骤

1. `_core-supervisor.md` 启动步骤改造，**最终步骤编号定死（CR3 P1-2）：1 参数解析 → 2 会话名固定与 sid 获取（SessionStart 注入行为主，实测⑦；缺失时 fallback 扫 `~/.claude/sessions/`，**匹配规则：name 相等且 cwd==project-dir，仍多条报错换名禁止任选**，CR2 P1-4）+ resume 恢复流程（**触发双通道：source=resume 注入提示机械触发（实测⑦）+ 巡检 prompt 常驻首条自检兜底**，CR2 P1-3；恢复动作：旧名未被占用才 rename 回，被占用选新唯一名，CR2 P2-1 → register upsert → 汇报中断点）→ 3 旧布局迁移条款（平铺 state.json 存在 → 问用户：归档或原地保留；未答不建分片；**旧账未完结时警告升级窗口后果，CR3 P1-3**）→ 4 registry 注册与并行隔离断言（见步骤 2（dev-1）专项）→ 5 state.json 初始化（分片路径 `.supervisor/<sid>/state.json`，分片目录随建）→ 6 ListAgents 自检与等待注册 → 7 cron 创建 → 8 初始指令下发**。core 内所有"启动步骤第 N 步"交叉引用按新编号逐条改写（cron prompt 重建条款、巡检三步引用等），grep "启动步骤第" 逐条核对（CR3 P1-2，沿用 scheduled-supervision 先例）。
2. **registry 注册与并行隔离断言（单次事务，CR P0-2；位于新步骤 4——迁移询问之后、分片/cron 创建之前，避免孤儿产物，CR2 P2-3 + CR3 P2-3）**——`~/.agent-mail/registry.py register [--branch]`（绝对路径调用，CR3 P2-4）：无他人活跃条目直接写入；有他人活跃条目 → 打印列表 exit 2，锁外用户确认隔离后带 `--isolation-confirmed` 重试（重读校验他人活跃集合未新增，CR2 P1-2）；**撞名 → exit 3 要求先 /rename（退出码分诊，CR3 P3-2）**；ESCALATE/叫停不写入条目。register 为按 sid 幂等 upsert（CR P1-1）；事务含名称唯一性断言（SendMessage 只认名称，dev-0 实测）。
3. **worker 身份登记改造（CR2 P0-1，实测⑦后简化）**：新步骤 8 现行"用 ListAgents 解析发送方 session_id"失效——改为 WORKER REGISTER 消息内 worker **自报本会话 session_id**（从 SessionStart 注入行获得），supervisor 校验 36 位 UUID 格式后**做一次 sessions 扫描交叉验证**（name+cwd，不一致以扫描为准并要求重报，CR3 P2-5）再写 workers[]；自报缺失/非法时同样走扫描 fallback；**非 Claude worker（Codex agent-mail 桥）session_id 记 null、channel 字段记 agent-mail，hook 层不覆盖（与 v2 一致）**；**WORKER REGISTER 消息模板同步增自报 sid 一行**。
4. 启动步骤 7（cron，原 6）：查重标识改"监工定时巡检(<本 sid 完整 UUID>)"（碰撞类风险零容忍，见 spec F2），巡检 prompt 里的重建条款同步改标识（含"重建时用自己的完整 sid"；**重建条款引用的步骤号按新编号改写**）。
5. 巡检步骤：新增 heartbeat_ts 更新（registry.py heartbeat，仅自己条目）；**新增 stale 活性检查条款（CR2 P2-2）**：按 name 检查他人条目活性（ListAgents 输出含该 name 即可达）、双条件（不可达且 heartbeat 超 30 分钟）、mark-stale 经 registry.py、绝不删他人。
6. 收尾（状态机 dev-N 第 4 条）：CronDelete 同时从 registry 注销自己（registry.py unregister）。
7. `interrupts.jsonl`/`acknowledged.jsonl` 全部路径引用改分片路径（grep 逐处核对：中断补课条含两文件、落账条款 acknowledged 一处——以 grep DoD 为准，不依赖计数）。
8. 顺手修存量漂移四处：启动步骤 2 "hook 靠 supervisor_session_id 前缀匹配"改"精确匹配"（CR P2-1）；"唤醒 worker 用 SendMessage 按会话寻址"改"按名称寻址（SendMessage 唯一可用键，dev-0 实测）"；"name 仅供展示"补"但它是消息路由的硬依赖"；启动步骤 7 "用 ListAgents 解析发送方会话，取得其 session_id"改"worker 自报 sid（SessionStart 注入行，实测⑦）为主"（CR2 P0-1，此项已提升为步骤 3 专项）。
9. 拼接门禁：`cat` 两模式层 + 新 core，与 v3 前拼接产物 diff——允许项仅限八类（与 spec DoD 5 一致）：路径换根、registry 注册心跳注销 stale 各一句、cron 标识改写、旧布局迁移条款、resume 恢复（双通道触发）与名称固定与 worker 登记（自报主+扫描 fallback）改造新增条款、WORKER REGISTER 模板增自报 sid 一行、存量措辞修正四处（含 ListAgents 推导 sid→注入行为主/扫描 fallback）、注册前置于分片/cron 的顺序调整。逐条归类，语义条款零丢失零弱化（沿用零回归 diff 门禁方法学）。

### DoD

- [ ] diff 归类清单落本 plan 附录（每条：所属允许类 / 语义等价说明）
- [ ] grep 核对：全文无残留平铺路径引用（`\.supervisor/state.json`、`\.supervisor/interrupts` 旧形态；**旧布局迁移条款本身必需的平铺路径字样豁免——按行含"归档/迁移/平铺"关键词排除，CR3 P2-2**）
- [ ] grep 核对：registry.py 调用条款（register/heartbeat/unregister/mark-stale 四时机）、stale 判定（双条件）、"绝不删他人条目"在 core 中均为命令式表述；core 明文禁止 LLM 直接编辑 registry.json；**调用写法均为绝对路径 `~/.agent-mail/registry.py ...`（无裸 registry.py，CR3 P2-4）**
- [ ] grep 核对：`"启动步骤第"` 交叉引用逐条与新编号一致（CR3 P1-2）

---

## dev-2 worker.md 发现改造（F3）

### 步骤

1. 注册步骤 1 重写：读 registry → 唯一活跃条目直接选 / 多条目展示（name/mode/goal_brief/branch）请用户指定 / 无条目走现行 ListAgents 兜底。
2. `--supervisor` 参数：接受**会话名称**（必须唯一，SendMessage 唯一可用寻址键——dev-0 实测 UUID/短 ID 均不可达；同名多条用 `<名>[<短ID>]` 消歧），frontmatter argument-hint 同步；**WORKER REGISTER 消息模板增自报 sid 一行**（从 SessionStart 注入行取，实测⑦；缺失时扫 sessions 注册表）；另加一条：worker 按监工名 SendMessage 失败时按"疑似死条目"路径报告用户并附三选项清单（resume / 稍后重试 / 转自主模式兜底：完成当前 phase 指令并 commit、不自行流转 phase、恢复后补审）（supervisor resume 重分配名字的窗口期同用此路径）。
3. 红线精确化："`.supervisor/` 永不 add、永不修改" → "registry.json 与分片目录**只读**；分片内容禁碰；`.supervisor/` 整体永不 add"。两处红线（并行协作纪律节 + 行为红线节）同步改。
4. 注册消息唯一改动（自报 sid 一行，dev-1 步骤 3 同步）；执行协议主体不动。

### DoD

- [ ] 注册步骤四分支齐全（唯一/多条/无条目/参数指定），每分支命令式
- [ ] 红线两处一致，无"永不修改"与"只读"措辞冲突
- [ ] worker.md 行数增量 ≤ 24 行（含死条目三选项清单与自报 sid，CR3 P2-7 放宽；超限则压缩三选项为简式）

---

## dev-3 hook 层改造（F4：注入器 + 守卫 + StopFailure 多分片解析 + worktree）

### 步骤

1. **新增 `hooks/session-start-injector.py`**（实测⑦背书）：读 stdin 取 session_id/source/cwd，stdout 单行 `SESSION_ID <uuid> <source>`；source=resume **且 `<cwd>/.supervisor/` 存在**时追加 supervisor 核对提示行（读 registry 本方条目引导——存在性门控保无关项目零噪音，CR3 P0-1）；dumb 脚本（不读会话状态、不写任何文件），异常静默 exit 0。
2. **新增 `hooks/shard-guard.py`**（实测⑧背书）：PreToolUse(Write|Edit)——tool_input.file_path 不含 `.supervisor/` 先短路（纯字符串判断直接 exit 0，不起解释器不解析 JSON）；疑似命中才解析，路径 uuid 与 stdin session_id 等值校验，不等 exit 2 + stderr 给正确 sid；**Write|Edit 目标为 `.supervisor/registry.json` 一律 exit 2（CR3 P2-1）**；archive/ 平铺写入放行。
3. `find_state_upward` 改造：`.supervisor/` 存在时先扫分片（**UUID 目录名白名单**，archive/ 与非 UUID 目录不可见，CR P0-1）；零分片回退平铺。返回 (state_dict, shard_dir) 二元组。
4. 分片选择：用 dev-0 实测定案的身份源（hook stdin 的 session_id）匹配分片的 `workers[].session_id`；sid 命中多个**活跃分片**（同 worker 先后注册进两个 supervisor 的形态）时取 registered_at 最新，仍不唯一不投递（归档分片因 UUID 白名单不可见，不进命中集合——复审补修：原"归档多命中"场景与白名单矛盾）。
5. `resolve_supervisor` pass-2 收紧：分片数 > 1 时禁用 pass-2，仅 supervisor_session_id 精确匹配（CR P1-4）。
6. worktree：向上找不到 `.supervisor/` 时，`git rev-parse --git-common-dir` 推主工作区根再找（仅当 start_dir 在 git 仓库内）。
7. interrupts.jsonl 落盘路径随选中分片。
8. test_stopfailure.sh 扩展用例：**八条新增用例（CR3 P3-6 称谓修正）**：多分片定向投递 / 多分片无匹配含双命中歧义不投递 / 平铺回退零分片时 / worktree 发现临时建 linked worktree / archive 不被扫描 / 双 supervisor 名字碰撞且目标 sid 死→不投递 / **分片存在但 sid 零命中时平铺兜底通道（CR3 P1-3）** / **守卫拦 registry.json 直写（CR3 P2-1）**；另加两 hook 各自用例：注入器（startup/resume 两种 source 输出、异常静默 exit 0）、守卫（正确分片放行 / 错 sid deny + stderr 含正确 sid / 短路路径零 JSON 解析 / archive 与平铺写入放行）。

### DoD

- [ ] 既有用例零改动全绿（存量行为不回归）
- [ ] 新增八用例全绿；注入器两断言 + 守卫四断言全绿
- [ ] hook 对分片目录的写操作仅 interrupts.jsonl 一处（grep 核对无越权写）；注入器零文件读写、守卫零文件写（grep 核对）

---

## dev-4 watchdog 分片适配（F5）

### 步骤

1. `watchdog.sh`：STATE 读取改为遍历分片（UUID 目录名白名单，排除 archive）+ 平铺回退；每分片独立逾期判定。
2. **告警路由改 UDS 直投（CR P1-2）**：复用 hook 的 send_uds 机制，按分片的 supervisor_session_id 精确匹配 `~/.claude/sessions/` socket 直投——agent-mail 名字路由废弃（多 supervisor 默认同名必串台）。
3. 去重状态分片化：`.supervisor/<sid>/watchdog_state.json`。
4. test_watchdog.sh 扩展：双分片独立告警 / 去重状态互不干扰 / 平铺回退 / archive 不被扫描。

### DoD

- [ ] 既有用例零改动全绿
- [ ] 新增三用例全绿
- [ ] 单分片场景 watchdog 行为与 v3 前一致（含告警文案）

---

## dev-5 install.sh + 文档同步（F6）

### 步骤

1. install.sh：新增 `registry.py` 安装（与 watchdog 同目录同方式，CR P1-3）；**新增两 hook 安装与 settings.json 注册**（SessionStart→注入器、PreToolUse(Write|Edit matcher)→守卫，与既有 StopFailure 注册同模式，重装幂等不重复追加）；收尾 echo 补多 supervisor 用法一句 + 平铺路径表述改分片语义（`.supervisor/interrupts.jsonl` → `.supervisor/<sid>/interrupts.jsonl`，CR P2-4）；其余零改动（拼接断言不受影响——core 新增内容全部落在既有节内，无新 `## ` 标题）。
2. README：多 supervisor 并存用法节（分支/worktree 隔离警示）、`--supervisor <会话名>` 说明（CR2 P1-5 修正）、旧账本归档说明、registry.json 进文件清单（运行时产物说明）。
3. DESIGN 新增第 13 节（七要素：分层动机/分片键选型/registry.py 锁载体取舍/物理隔离裁决/死条目不对称处置/UUID 白名单 archive 隔离/**hook 化三件套取舍**——sid 获取与分片键防错升级为机械保证、PostToolUse 自动 register 评估后未纳入的理由）+ §9 已知边界补"同分支混行不支持"。
4. 行数实测回填 DESIGN 体积预算（core/worker 增量）。

### DoD

- [ ] grep 无过时表述（"单 supervisor"/"唯一监工"类与 v3 矛盾的措辞）
- [ ] DESIGN 13 节七要素齐全，行数与实测一致
- [ ] install.sh 重装幂等（产物 diff 为空；settings.json hook 注册不重复追加）

---

## dev-6 回归 + 双 supervisor 冒烟 + 收尾

### 步骤

1. 全量回归：test_stopfailure.sh（含新用例）+ test_watchdog.sh（含新用例）。
2. 本地真实安装 + 单 supervisor 注入实测（/supervisor 与 /rework 各一，验证分片账本落位、registry 注册、旧布局迁移询问分支）；**hook 化真机验证**：安装后会话上下文可见 SESSION_ID 注入行（实测⑦工程化落地）、守卫对错 sid 写分片的真实拦截与 stderr 纠错。
3. **双 supervisor 冒烟**（spec DoD 2）：同 project-dir 起 greenfield + rework 双 supervisor → 各自 worker 注册路由正确（**workers[].session_id 为真 UUID 且 hook 可命中**，CR2 P0-1 下游检查）→ 账本互不可见 → **各自终端 CronList 各见且仅见本方 UUID 巡检（跨会话不可见即隔离证据，CR2 P1-1）** → 一方收尾注销 → registry 只剩另一方；**registry 并发首建竞态合成测试**（CR P2-3）；**`<名>[<短ID>]` 消歧语法实测（失败则删形式改提示 rename，CR2 P2-5）**；**register 两阶段事务实测（--isolation-confirmed 流程，CR2 P1-2）**；**双 project-dir 同名 supervisor 边界实测（CR3 P1-1：跨项目 SendMessage 寻址是否串台、stale 假活现象；结论回填 DESIGN §9）**。全程最小目标，走完注册与首轮上报即可，不做完整项目。
4. worktree 冒烟（spec DoD 4）：linked worktree 中触发 StopFailure（模拟），验证投递到所属分片。
5. spec §6 五项 DoD 逐条勾验；挂账清单汇总；最终 commit。**补验 dev-0 第 6 项遗留子项（CR2 P2-7）：idle 存活会话在 ListAgents 的可见性**（stale 按 name 判可达的语义依赖；不可见则 stale 退化纯 heartbeat 判定，需回填结论）。

### DoD

- [ ] 全量回归全绿（存量 + 新增用例）
- [ ] 双 supervisor 冒烟四步证据齐全（路由/隔离/双 cron/注销）
- [ ] worktree 投递实测通过
- [ ] spec §6 五项勾验；挂账清单（预期至少三条：双 supervisor 真实项目长跑（含分支隔离下真实并行）/ stale 双条件判定与死条目用户裁决路径的协议级演练（无法脚本化）/ hook 错投零事故的长尾观察）

---

## 明确不做清单

- 不做 supervisor 间通信与协调（互不感知，冲突升级用户）；
- 不做死条目自动清除（只标记 stale，删除仅限注销自己）；
- 不做同分支混行的智能范围比对；
- 不做跨项目/跨机器 registry；
- 不在本轮做双 supervisor 真实项目长跑（冒烟即止，长跑挂账）。
