# LMUX 项目阶段总结 (v2)

## 项目概述

LMUX — 基于 SwiftUI + Go 后端的多 Agent 终端管理器，支持 CodeBuddy 和 Claude Code。

## 本阶段新增功能

### 1. 多 Agent 支持
- `AgentType` 枚举（codebuddy / claude）
- 新建 Session 面板的 Agent 选择器
- 不同的启动参数：CodeBuddy `--permission-mode auto -y`，Claude `--dangerously-skip-permissions`
- Go 后端存储 `agent_type` 字段
- SessionRestore 持久化 agentType

### 2. Session 生命周期
- **新建 Session**：默认启动 zsh 终端，cd 到项目目录
- **恢复 Session**（有 cbcSessionID）：启动对应 agent
- **Terminal 分屏**：底部 bash/zsh 终端面板
- **Stop 按钮**：终止进程，保留 session 元数据
- **Delete（右键）**：永久删除 session + restore 数据
- **Attach in Terminal**：实现右键菜单重连
- **Session 命名**：默认使用项目目录名

### 3. 会话状态指示器
- 绿色圆点 = 有 PTY 输出
- 灰色圆点 = 无输出
- 旁侧栏 `running` / `idle` 状态文本（3 秒无输出 = idle）
- 通知提醒环：后台 session 完成时橙色脉动 + macOS 通知

### 4. OSC 9/777 通知协议
- 注册自定义 OSC handler 拦截 agent 通知序列
- 发送 macOS 桌面通知

### 5. 终端主题
- 8 个预设主题（Dracula 默认）
- Preferences 面板（File > Settings）

### 6. 会话恢复
- `SessionRestore` 持久化到 `~/Library/Application Support/lmux/restore.json`
- 应用重启时自动重连之前运行的 session

### 7. 其他
- Scrollback 500 → 1,000,000 行
- 日历/照片/通讯录权限禁止
- macOS 12 兼容（SF Symbol 替换为文本按钮）

## 已知问题

| 问题 | 状态 |
|------|------|
| ~~Claude agentType 在重启时被 codebuddy 覆盖~~ | ✅ 已修复 (`b425a6f`) |

## Agent 类型检测与恢复 (`b425a6f`)

**问题**：新建 Claude session → bash 终端 → 用户手动启动 claude → 关闭 app → 重启后恢复为 codebuddy。

**方案**：
- `SessionRestore.LaunchMode` 枚举（`.bash` / `.agent`），记录 session 启动模式
- `TerminalManager.connectBash()` 中启动定时器，用 `pgrep` 检测 bash 终端中正在运行的 agent 进程
- 检测到 `claude` 或 `codebuddy-code` 后，自动更新 `restore.json` 中的 `agentType` 和 `launchMode`
- 恢复时根据 `launchMode` 路由：`.bash` → `connectBash()`，`.agent` → `connect()`
- 旧版 `restore.json` 无 `launchMode` 字段自动视为 `.bash`（向后兼容）

## 提交统计

本阶段累计 **39 个提交**，涵盖：

```
34d617e fix: make agentType required in connectBash
81bd0a1 fix: always remove session from restore list on delete
06a6d32 fix: use OutputAwareTerminalView in connectBash for activity/idle tracking
c77310d fix: restore agent session correctly on restart
...
316d5b1 fix: lower Swift tools version to 5.7
```

## 文件结构

```
Sources/LMUX/
├── App.swift                    # 入口 + 通知权限
├── Models/
│   ├── Session.swift            # 数据模型 + AgentType 枚举
│   └── Theme.swift              # 终端主题预设
├── Network/
│   └── APIClient.swift          # REST 客户端
├── Utils/
│   ├── TerminalManager.swift    # PTY 生命周期 + OSC 通知 + zsh/bash
│   └── SessionRestore.swift     # 会话持久化
├── ViewModels/
│   └── ContentViewModel.swift   # 状态管理 + 后端启动 + 恢复
└── Views/
    ├── ContentView.swift        # 主布局
    ├── SessionListView.swift    # 侧边栏 + 状态指示器
    ├── SessionDetailView.swift  # 终端面板 + 分屏 + Stop/Terminal 按钮
    ├── TerminalView.swift       # NSViewRepresentable 桥接
    ├── NewSessionSheet.swift    # 新建会话（Agent 选择器）
    └── PreferencesView.swift    # 主题选择

backend-src/
├── cmd/cbsm/main.go             # Go 后端入口
├── internal/
│   ├── api/                     # HTTP 服务器 + 路由
│   ├── session/                 # Session CRUD + SQLite
│   ├── codebuddy/               # JSONL 扫描
│   └── config/                  # 配置
```

## 今日修复 (2026-08-04, v1.0.6)

共 **31 个提交**，解决以下问题：

### 终端切换重载问题

切换 session / 开关分屏 / 调整窗口大小时，agent 终端会重新加载对话。

**尝试方案**（多轮迭代）：ZStack overlay、固定 outer frame、PTYTerminalView 位置稳定化、connectedSessionId 保持 View 身份、防轮询重连。

**结论**：窗口缩放重载 = SIGWINCH + TIOCSWINSZ（标准终端行为）；`/skills` 命令触发的重载可能是 agent 内部行为，非 lmux 层问题。

### CSI 3 J 滚动历史清除

`CSI 3 J` escape sequence 导致对话历史丢失。

**修复**：跨边界部分序列处理 → 最终在 SwiftTerm 层禁用该 escape sequence。

### 性能优化

- scrollback 1M → 50K 行
- isIdle 更新从每次数据块 → 每 2 秒节流
- 终端 frame 未变化时跳过 NSView 更新

### 版本管理

- 侧边栏显示版本号
- 自动 bump 脚本 + pre-commit hook
- Info.plist 同步版本（About 对话框）

### cbcSessionID 回退

当 restore.json 缺失时，回退到后端存储的 cbcSessionID，确保已有 session 对话历史不丢失。
