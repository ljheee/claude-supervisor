# ch1 探针记录 2026-09-09 19:52:40
## P1 版本
2.1.259 (Claude Code)

## P2 tasks 目录统计
(eval):10: no matches found: session-*
UUID 目录数: 0
session- 目录数: 67
任务 json 总数: 924
status 分布:  830 "status": "completed";  12 "status": "in_progress";  82 "status": "pending";

## P3 会话注册表（sessions/）当前活跃
       9

## P4 后台会话（claude agents --json 摘要）
opensource-project-opportunities-pipelin-1f interactive idle 
opensource-project-opportunities-framewo-cf interactive idle 
economy-strategy-19 interactive waiting input needed
research-smoke-89 interactive idle 
research-smoke-3a interactive idle 
claude-supervisor-86 interactive idle 
claude-supervisor-18 interactive busy 
observer-sessions-1a interactive None 
observer-sessions-6e interactive None 

## P5 jobs 目录（--bg 后台任务）
   098f9eb0 failed | /research 调研本仓 app.py→utils 依赖现状与已知债务：列出全部 TODO/FI
   71ed6d59 failed | /research 调研本仓 app.py→utils 依赖现状与已知债务
   922d8999 failed | /research 调研本仓 app.py→utils 依赖现状与已知债务：列出全部 TODO/FI
   b2cf7d69 failed | /research 调研本仓 app.py→utils 依赖现状与已知债务：列出全部 TODO/FI
   d0011ea3 failed | 派subagent 仔细CR 人B 功能项，确定是真问题的，执行修复

## P6 session-77541 waitingFor 实证（7b-同步本地对照）
status: waiting / waitingFor: input needed

## P7 resume/continue 帮助原文
                                        --resume <session-id>, continues that
                                        session in the background under the same

## P8 TodoWrite 持久化与双命名（追加探针）
- TodoWrite 输入格式（transcript 实证，fe519e5a 会话）：`input: [{content, Active-Form, status}]` 数组，status ∈ in_progress/pending/completed
- 持久化位置：`~/.claude/tasks/<sessionId>/`（194 个 UUID 目录，跨会话生命周期持久——目录存活期 8/17~9/6，进程退出不删）
- 命名变更：9/7 起新会话改用 `~/.claude/tasks/session-<uuid前8位>/`（67 个，含本会话 f11e1dc6 空目录——本会话未用 TodoWrite，目录随会话启动即创建）
- 跨 resume 持久实证：session-e2386d9a（2.1.212）任务 id 4-15，文件时间 8/28-8/29 跨多个回合持续追加；8/29 12:30 后仍能 in_progress 挂起（15.json：手动轮询 backfill 进度）
- 项目目录对照：`~/.claude/projects/<project>/<uuid>/` 子目录是 tool-results 等会话数据，与 tasks/ 无关
- 结论：TodoWrite = 会话级持久（进程死文件在，resume 后继续可用），但无用户级聚合视图——924 个任务 json 分散在 261 个会话目录里，官方无任何"跨会话查全部待办"的入口

## P9 history.jsonl（用户级，但只是提示词历史）
- `~/.claude/history.jsonl` 3090 行，跨全部项目记录用户输入的 prompt（display/project/timestamp），非任务态
- 可作用户级任务管理器的"需求入口考古"数据源（用户提过的需求都在），但无状态跟踪
