# lmux — 进度与路线图

**更新日期:** 2026-09-05
**当前版本:** 1.0.171+（master 单线双产物；swiftterm 已冻结并入）

---

## 当前功能全景

- **多会话管理** — 左侧会话列表，点击切换，detach/reattach 保留进程状态
- **双渲染后端** — SwiftTerm（forkpty）与 Ghostty（libghostty exec + viewport 轮询），Preferences 可切换
- **多 Agent 支持** — CodeBuddy / Claude，`--resume <id>` 恢复历史，find-session 绑定
- **会话生命周期** — 右键 Attach / Edit / Rename / Delete / Export / Import；Kill 停止；分屏终端
- **上下文监控** — 侧边栏显示上下文百分比 + 当前模型名（CodeBuddy JSONL usage 实时扫描）
- **会话导出/导入** — `.lmuxsession` 自包含文件（agent 类型、项目目录、会话 ID、完整 JSONL），支持冲突覆盖/新建副本
- **会话编辑** — 修改项目路径（跨机器路径不一致）、会话名、绑定对话 ID（仅停止状态可编辑）
- **通知** — OSC 9/777 桌面通知、后台完成提醒环
- **整机备份** — 导出/导入 tar.gz（含 sessions.db、codebuddy/claude 配置与对话）
- **主题** — 8 个预设终端主题，实时切换
- **文件拖拽** — 拖文件到终端插入引用路径

---

## 近期完成（1.0.117 → 1.0.132）

| 版本 | 内容 |
|------|------|
| 1.0.117+ | Ghostty 集成收尾、session 绑定修复（fresh launch 用微秒级 notBefore 定位独立会话；`/resume` 回退最近修改文件；修复"重启后新会话恢复成他人 /skills 会话"） |
| ~1.0.121 | 模型名显示：移除积分/¥ 显示，改为当前会话模型名（backend AgentContext 返回 `model` 字段） |
| 1.0.125 | **会话导出/导入** + **会话编辑**（project_dir/cbc_session_id/name）+ 启动时替换旧 backend |
| 1.0.129 | session 行 agent badge 移到状态行，长名称不被截断 |
| 1.0.131-132 | session 状态行精简：只保留运行时长 + agent 名（gitBranch/aiTitle 移除） |

### 技术要点（近期）

1. **会话绑定三机制**（`scanner.go latestSessionFile`）：
   - 全新启动：进程启动后 `notBefore`（proc_pidinfo 微秒）内最早创建的会话文件
   - `/resume <id>`：无新文件创建时，回退到启动后最近修改的文件
   - 多会话并发：各会话只绑定自己创建的文件，避免互相抢占
2. **导出/导入**（`.lmuxsession`）：
   - 后端 `GET /api/sessions/{id}/export` + `POST /api/sessions/import`
   - 冲突检测 → 客户端弹窗选择 `overwrite`（覆盖文件+复用记录）或 `new`（UUID 改写 sessionId，独立副本）
   - `RewriteSessionID` 用正则改写 JSONL 内所有 `sessionId` 字段
3. **会话编辑**（`POST /api/sessions/{id}/edit`）：
   - 仅停止状态可编辑；project_dir 校验存在 + 重算 git branch
   - 编辑后 `SessionRestore.remove` 防 restore.json 旧路径覆盖
4. **backend 热更新**：启动时若 `.build` 后端二进制更新，替换运行中的进程

---

## 已知问题

| # | 问题 | 状态 | 分析 |
|---|------|------|------|
| K1 | 侧边栏上下文百分比与 `/context` 不一致 | 已知 | lmux 用 JSONL 最后一条 usage 记录的 model 决定窗口（deepseek-v4-flash=1M）；`/context` 用当前模型实际窗口（如 hy3≈192K）。切换模型后两者基准不同，属预期但可优化 |
| K2 | Attach in Terminal 对已选中会话无操作 | 已确认 | 选中态 id 不变 → onChange 不触发，符合预期（已在查看无需再连） |
| K3 | TCC 权限弹窗（音乐/相册等） | 缓解未根治 | ad-hoc 签名无稳定 TeamIdentifier，根治需 Developer ID 证书 |
| K4 | 修改 project_dir 不迁移 JSONL | 已知 | 用户选择"仅改记录"；改路径后 find-session/export 按新路径找文件，若对话文件在旧路径则找不到 |
| K5 | `/skills` 命令导致对话重载 | 已知不可修 | Agent 层面行为 |

---

## 下一阶段规划（候选，按价值排序）

### P0 — 使用频率最高，建议优先

1. ✅ **上下文超限提醒**
   - 侧边栏百分比 ≥80%/90% 时桌面通知 + 提示执行 `/compact`
   - 复用现有 OSC 通知通道；每会话每阈值只通知一次，回落后可重触发
2. ✅ **会话置顶/收藏 + 分组折叠**
   - 后端 `pinned` 字段（迁移 v2）+ `POST /api/sessions/{id}/pin`，列表按置顶优先排序
   - 前端置顶组 + 按 agent 类型分组，可折叠；右键 Pin/Unpin，行内星标
3. ✅ **上下文/成本统计面板**
   - `GET /api/sessions/usage` 聚合每个会话 tokens/credit/model/context_window
   - 前端 Usage Statistics… 面板：按积分/Token/上下文/名称排序，上下文进度条

### P1 — 导入导出增强（延续现有功能）

4. ✅ **跨设备同步**（用户新增紧急需求，2026-08-28）
   - 云盘目录（iCloud/Syncthing）+ 双向 + 仅置顶会话 + 实时（15s 轮询）
   - `.lmuxsession` 文件 + `device_id` 防回环 + mtime 变更检测
   - 路径映射表（设置里配置 旧路径→新路径，导入时自动替换 project_dir 和 JSONL cwd）
   - 冲突自动保留两份（复用 import conflict_mode="new"）；删除不传播
   - 后端 `ExportSession` 增加 `content_modified_at`（JSONL mtime）供变更检测
5. **拖拽导入** — `.lmuxsession` 文件拖进窗口直接导入
6. **批量导出** — 多选会话一键导出多个文件
7. **导入预览** — 导入前显示会话名/大小/agent/对话条数
8. **导出 JSONL 时同步 cwd** — 可选重写 JSONL 内 cwd 字段，解决跨机器路径问题

### P2 — 终端体验

8. **终端复制/查找** — 选中文本复制按钮 + 终端内 Cmd+F 高亮
9. **Tab 标签页** — 单窗口多终端标签
10. **Cmd+数字快速切换** — 最近会话快捷键
11. **会话归档隐藏** — 不删除但移出主列表

### P3 — 稳定与工程

12. **Developer ID 签名** — 根治 TCC 权限弹窗（K3）
13. **backend 路径相对化** — Package.swift 改相对路径，方便换机器
14. **backend/lmux 二进制不入库** — 作为构建产物，由 Makefile 生成

### P4 — 锦上添花（2026-08-28 用户确认全选）

> 参考 2026 年 CLI Agent 行业趋势（Claude Code /loop + Transcript 搜索、Kiro checkpointing、Copilot /undo、Aider git 集成）。lmux 已具备 JSONL 读写、通知、统计、导入导出能力，以下功能复用这些基础。

15. **会话 Checkpoint 回滚**
    - 右键「创建检查点」→ 复制 JSONL 快照到 `~/.lmux/checkpoints/<cbcID>/<ts>.jsonl`
    - 右键「回滚到此检查点」→ 覆盖当前 JSONL（先备份当前为反悔点），清 find-session 缓存
    - 列表显示检查点数量 + 时间；可删除检查点
    - 后端：`POST /api/sessions/{id}/checkpoint`、`GET /api/sessions/{id}/checkpoints`、`POST /api/sessions/{id}/restore-checkpoint`
16. **会话全文搜索**
    - 后端扫描所有 JSONL 提取消息文本（已有 parseJSONL 基础），`POST /api/search` 按关键词/正则匹配
    - 前端 Cmd+Shift+F 搜索面板：命中会话 + 消息预览 + 时间，点击跳转到该会话
17. **导出可读报告**（Markdown/HTML）
    - 后端把 JSONL 渲染成对话流（用户/assistant/tool 消息），`GET /api/sessions/{id}/export` 增加 `format=md|html` 参数
    - 前端右键「Export as Report…」→ 保存 .md/.html，可含上下文%、模型、时间戳
18. **会话工作摘要**
    - agent 完成后自动生成「本轮做了什么」摘要：读 JSONL 尾部消息 + git diff 统计（文件改动数/增删行）
    - 存入 session.ai_title 或单独字段，显示在列表 + 通知里
19. **项目级记忆**
    - 按 project_dir 聚合所有会话的摘要/AI title，生成项目记忆文本
    - 新建该目录会话时可选注入记忆作为初始 prompt（或在面板查看）
20. **定时监控 /loop**
    - 对后台会话定时执行命令（如 `git status`），结果变化时通知（复用现有通知通道）
    - 前端：会话右键「Schedule…」设置间隔/命令；后端或前台 timer 执行
21. **Git 集成增强**
    - 会话内检测 git 状态变化，完成后显示改动统计
    - 右键「Commit…」自动生成 commit（结合工作摘要）；查看会话关联 commit 记录

---

## 分支状态（2026-09-05 重构后：单线双产物）

```
master                    → 唯一开发线（当前 1.0.171+）
                            make app      = lmux.app     Ghostty / macOS 13+
                            make app-st   = lmux-st.app  SwiftTerm / macOS 12
                            make app-x86  = lmux-st.app  Intel x86_64 / macOS 12
swiftterm                 → 已冻结（git tag lmux-st-final），能力并入 master
                            Package.st.swift 仅作 st 变体 manifest，代码与 master 同源
feature/ghostty-renderer  → 已并入 master（历史）
```

## 构建与发布

```bash
cd lmux-app && make app      # Swift 前端 + Go 后端 + 打包（backend 为构建产物，不入库）
cd lmux-app && make app-st   # macOS 12 SwiftTerm 变体（独立 bundle id com.manshiangli.lmux-st）
make test                    # 前端单元测试（arch -arm64）
./bump-version.sh            # 版本 +1（Version.swift + Info.plist）
# 安装：替换 /Applications/lmux.app（旧版备份 lmux.app.bak）或 lmux-st.app
```

---

## 会话日志（2026-09-06）

### Accomplished

1. **Agent 浏览器（M1/M2 已交付并部署）**：Sessions/Agent 分段切换；全页双栏（左筛选列表 / 右预览）；扫描限定一层排除 `subagents/`；按 `agent+id` 去重（还原副本多拷贝只留最新）；预览按 `file_rel` 定位（agent 漫游 cd 后 cwd≠存储目录）；解析新版 codebuddy `output_text`/`input_text` 块，tail 512KB 覆盖整轮；列表隐藏已绑定 lmux 会话（`hidden` 计数 + UI 提示）。
2. **Agent JSONL 镜像同步（M2）**：`<syncDir>/agents/<agent>` 双向同步原始 JSONL；size 指纹防回环；append 增量；>50MB 跳过；restoreAgentFileIfMissing 用于 resume。
3. **大量 UI 布局迭代**（重启生效）：删除窗口顶部工具条（terminal 更高）；Sessions/Agent 切换两页统一钉在左上（左对齐，切页不跳）；列宽统一 275（共享 `AppStorage("columnWidth")`）；搜索框回 Session 列顶；New Session 全宽长按钮；底部 (⋯) 菜单（Sync Now / Settings… / About lmux）；设置统一 `SettingsWindowController` 可复用 NSWindow（原 SwiftUI Settings scene 移除，Cmd+, 也走它）；Sync Now 模态等待窗。
4. **阶段 1 同步可靠性（本次会话末交付）**：镜像决策下沉 `LMUXCore/AgentMirrorPolicy`（+11 单测）；`AgentMirrorIO.appendTail` 下沉（+2 字节级单测）；同步进度阶段化（等待窗实时阶段 `Exporting i/N`/`Agent conversations · …`）；双边冲突面板 `MirrorConflictPanelView`（逐文件 Keep Local / Use Mirror，替换后指纹正确处理防再推旧内容）。
5. **Makefile 修复**：`BINARY_ST` 改用 `.build-st/debug` symlink 路径（swiftpm 产物目录 arm64/x86 变化导致 cp 失败）。
6. **单测强化**：Swift 54→67 全绿；Go api+codebuddy 全绿（去重/过滤/claude 预览/按 id 定位提纯函数+测试）。

### Next Steps（明天继续）

1. **推送**：远端停在 `9026d42`。本地 8 个提交未推（Agent 浏览器系列全部 + 阶段1 等），网络曾连续超时。网络恢复后 `git push origin master`（勿重复提交，`git log origin/master..HEAD` 为基准）。
2. **阶段 2 并行工作台**（计划已批）：`SessionDetailView` 参数化（脱离 selectedSession）→ 新增 `SessionWindowController`（复用 per-session TerminalManager，backend 已按会话隔离）→ Session 行右键/菜单 "Open in New Window"。
3. **阶段 3 Agent 浏览器体验**：收藏/标签、resume 加载态、预览直接发消息评估。
4. 已知回环注意：TaskList #76-79 已完成（阶段1）；阶段 2 任务尚未创建。

### Blockers/Questions

- 推送 GitHub 网络不稳定（443 超时），重试即可。
- `libghostty-spm`/`swift-argument-parser` gitlink 漂移未提交（历史遗留，勿动）。
- mirror I/O 绑定 home+defaults，真实双目录冒烟需在 UI 手动 Sync Now 验证（policy 已单测覆盖决策/防回环）。

### Session Log · 2026-09-06（续）

- 推送：`9026d42..ff8e4f2`（8 个提交：Agent 浏览器系列 + 阶段1 同步可靠性 + 单测 + Makefile/UI 修复）。
- **阶段 2 并行工作台（fad8638）**：`SessionDetailView` `pinnedSession` 独立窗模式；`SessionWindowController`（按会话 NSWindow 复用，主窗占用/已弹窗防双 attach，关窗自动 `detach()` 后台保活）；Session 行右键 "Open in New Window"；主窗点选已弹窗会话 toast 提示。
- **阶段 3 Agent 浏览器体验（5a9b95d）**：星标收藏（`agent_browser_stars` 持久化、行尾/预览星标、Favorites section 置顶、★ 只看收藏筛选）；resume 加载态（`TerminalManager.isConnecting` 至首输出/2.5s；终端 overlay "Starting X — resuming conversation…"）；预览 user 消息 Copy 按钮。直发评估：CLI 均支持 `-p`，需临时进程+实时回读，成本高 → 降级为复制复用。
- 测试 67 全绿；三方向计划（同步/并行/Agent 体验）全部落地，已部署 master+st。
- 待推：阶段 2+3 两 commit 已在本会话末随本日志推送。

### Blockers / 后续候选

- 阶段 2 真实多窗口并发 attach（Ghostty surface 迁移）需用户在 UI 实测；若 pop-out 后进程卡死/窗口无输出，考虑限制多窗仅 SwiftTerm 或后端 per-window 方案。
- 预览直发消息（`-p` 单发 + 实时回读）若用户提出再做。
- 未做：工程基建方向（Swift 测试 target 全量覆盖、CI）。
