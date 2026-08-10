# lmux 开发进度文档

> 更新日期：2026-08-11 ｜ 当前分支：`feature/ghostty-renderer`（macOS 13+）｜ 原 `2.0` 分支支持 macOS 12

## 一、项目简介

lmux 是一个 macOS 终端会话管理器（SwiftUI + Go 后端）。侧边栏管理多个 **codebuddy / claude** agent 会话，支持会话恢复、上下文占用统计、agent 检测、分屏终端等能力。

## 二、版本演进

| 版本 | 阶段 | 说明 |
|------|------|------|
| 1.0.0 - 1.0.85 | 功能修复 | 会话恢复、agent 检测、上下文统计、导出等（fix/crash-issues 分支） |
| **1.0.86 - 1.0.97** | **2.0 重构与质量** | 错误反馈、测试、架构分层、快捷键、导出/导入、图标（2.0 分支，macOS 12） |
| **1.0.98+** | **Ghostty 渲染** | 双后端（SwiftTerm/Ghostty），macOS 13+（feature/ghostty-renderer 分支） |

## 二点五、feature/ghostty-renderer 分支（macOS 13+）

> 分支职责：**仅 macOS 13+**，引入 libghostty GPU 渲染作为可选后端；macOS 12 支持保留在 `2.0` 分支。
> 依赖：`libghostty-spm`（本地 path，untracked，XCFramework 已 vendor 于 `libghostty-spm/vendor/`，sha256 已验证）。

### 渲染后端抽象（TerminalBackend）
- `Sources/LMUX/Utils/TerminalBackend.swift`：协议 + `TerminalBackendFactory` + `UserDefaults` 开关（`terminalRenderer`: `swiftterm`/`ghostty`）
- `TerminalManager` 仅依赖 `TerminalBackend` 协议，不依赖具体渲染库
- `PreferencesView` 新增「Terminal Renderer」分段选择

### SwiftTermBackend
- 迁移自原 `TerminalManager`：`LocalProcessTerminalView` + forkpty、`OutputAwareTerminalView`（首输出/活动检测）、OSC 777/9、主题、scrollback
- 行为与 2.0 分支一致（零回归）

### GhosttyBackend（libghostty，macOS 13+）
- `.exec` 后端：libghostty 内部 PTY + spawn，宿主只传 workingDirectory/envVars/command
- Metal GPU 渲染；`TerminalViewState` 作为 delegate（title/resize/close/notification 原生回调）
- **idle/首输出**：exec 后端宿主拿不到字节流 → 轮询 `readViewportText()`（1s，hash 比对），与 SwiftTerm 的 dataReceived 语义等价
- **OSC 777/9 通知**：Ghostty 原生 `desktop_notification` action → `onNotify`
- **主题**：`TerminalTheme` → `TerminalConfiguration`（颜色经 `TerminalColorBridge`，实时 `setTerminalConfiguration`）
- **PID 适配**：`foregroundPid`（tcgetpgrp）语义与 SwiftTerm `shellPid` 不同；idle timer 同步 PID
- 对 `libghostty-spm` 的增量：`TerminalSurface.readViewportText()`（public）、`TerminalSurface.close()`（public）

### 构建
- 平台：`Package.swift` `.macOS(.v13)`；`Info.plist` `LSMinimumSystemVersion=13.0`
- 依赖：`.package(path: "libghostty-spm")` + `.product(name: "GhosttyTerminal")`
- 运行时切换后**仅影响新连接会话**；已运行会话保持原后端

## 三、2.0 分支已完成开发项

### 1. 错误反馈（提交 `9f65610` `5c111a3` `30a9a94`）
- **连接错误文案**：agent 二进制缺失/启动失败/shell 缺失给出可操作提示（含安装/PATH 建议）
- **终端区域错误视图**：连接失败在终端区域显示 `ConnectionErrorView`（非空白屏），可 Dismiss
- **删除确认**：删除 session 前弹出确认对话框（防误删）

### 2. 单元测试（提交 `f271d44` `ff3ee19`）
- **后端 Go 测试**：`encodeClaudeProjectDir`、`estimateContentChars`、`GetClaudeContextTokens`、find-session 创建时间逻辑
- **前端测试**：`resolveSession` 的 resume/fresh/bash 全分支（codebuddy + claude）、claude 丢弃 codebuddy 会话 ID、进程检测
- **测试发现并修复**：`extractSessionID` 循环漏掉尾参 bug（`--session-id=` 在最后时被跳过）

### 3. 架构重构（提交 `ff3ee19`）
- 提取 **LMUXCore 库 target**：`AgentType`、`AgentProvider`（协议/两个 Provider/AgentBinaryLocator）、`SessionRestore`
- 主流程只依赖 `AgentProvider` 协议，**加新 Agent 零改动主流程**，互不影响
- app target 依赖 LMUXCore，测试 target 依赖 LMUXCore（可测试 executable 无法承载的纯逻辑）

### 4. 快捷键与搜索（提交 `752be84`）
- Session 菜单：`Cmd+F` 搜索、`Cmd+↑/↓` 切换会话（遵循过滤）、`Cmd+K` 停止
- 侧边栏搜索框（按名称实时过滤）

### 5. 操作反馈与可靠性（提交 `046be73`）
- **toast 提示**：停止/创建/重命名/删除/连接成功，顶部非模态 2.5s 自动消失
- **退出清理**：`applicationWillTerminate` 统一 terminate 所有 agent/终端进程（无孤儿进程）
- **性能缓存**：后端 find-session 3s TTL；agent 检测命令行 5s TTL（含 PID 存在检查）

### 6. Review 低风险点处理（提交 `0ad7c99`）
- find-session 缓存 TTL 5s → 3s
- 创建/删除 session 时清 find-session 缓存
- `getCommandLine` 缓存用 `kill(0)` 验证 PID 仍存在（防 PID 复用）

### 7. 数据迁移（提交 `c42b79e` `bb385f4` `51f8627`）
- **导出脚本** `tools/export-lmux.sh`（命令行）
- **app 内导出/导入**：Session 菜单 → `Export Sessions…` / `Import Sessions…`（tar.gz 打包/解压 + 自动重启后端）
- **跨用户名迁移**：导入时自动检测用户名差异（如 `limanshiang` → `manshianglee`），自动重命名 codebuddy/claude 项目目录、改写 sessions.db / restore.json / 对话 JSONL 中的路径

### 8. App 图标（提交 `1781e06`）
- `tools/gen-icon.swift` 程序化渲染（深色渐变 + 绿色 `>_` 提示符 + 光标）
- 生成多尺寸 iconset → `AppIcon.icns`，`CFBundleIconFile=AppIcon`

## 四、架构

```
LMUXCore（库 target）
  ├── AgentType              # 枚举 + 属性（displayName/symbolName/launchArgs…）
  ├── AgentProvider          # 协议：prepareEnvironment / resolveSession / findBinaryPath / detectProcess / contextUsage
  │     ├── CodebuddyProvider
  │     ├── ClaudeProvider
  │     └── AgentBinaryLocator  # 二进制查找（本机优先、arm64 优先、跳过 stub）
  └── SessionRestore         # restore.json 读写（带缓存）

LMUX（app target，依赖 SwiftTerm + LMUXCore）
  ├── ViewModels/ContentViewModel   # 会话/后端/搜索/导出导入/清理（@MainActor）
  ├── Views/  # SessionListView（搜索/徽章/上下文）、SessionDetailView（终端/错误视图）、ContentView（toast）
  ├── Utils/TerminalManager  # PTY、agent 检测、idle 状态
  └── Network/APIClient      # HTTP + AgentSessionService

后端（Go）
  ├── /api/sessions、/api/agent/find-session、/api/agent/session-valid、/api/agent/context
  ├── codebuddy/  # JSONL 扫描、context 统计、find-session（创建时间 + 缓存）
  └── session/    # SQLite 存储
```

## 五、测试

| 位置 | 方式 | 覆盖 |
|------|------|------|
| 前端 LMUXCoreTests | `swift test` | 15 个用例：resolveSession 分支、进程检测、extractSessionID、颜色桥接 |
| 后端 | `go test ./...` | find-session 创建时间、context 估算、路径编码 |

## 六、已知问题 / 待办

- **claude 上下文为估算值**（claude JSONL 无 usage 计数器，按消息字符/2 估算）
- **session 分组/排序**（按 agent/状态）未实现
- **finder-session 缓存 TTL** 在"新建会话后立即重启"的 3s 窗口内可能返回旧值（低风险）
- 导入跨用户名迁移已覆盖 codebuddy/claude 项目目录与路径字段，**工程代码文件不在备份内**（需手动拷贝/git）

## 七、使用说明（关键操作）

- **新建会话**：`Cmd+N`
- **搜索**：`Cmd+F`；**切换**：`Cmd+↑/↓`；**停止**：`Cmd+K`
- **导出/导入**：Session 菜单 → Export/Import Sessions…
- **迁移到另一台电脑**：导出 tar.gz → 另一台（同用户名自动兼容，不同用户名自动迁移）→ 导入

## 八、2.0 分支提交清单

```
9f65610 连接错误文案
5c111a3 终端区域错误显示
30a9a94 删除确认
f271d44 后端 Go 测试
ff3ee19 LMUXCore 库 + 前端测试 + extractSessionID 修复
752be84 快捷键 + session 搜索
046be73 toast + 进程清理 + 性能缓存
0ad7c99 review 低风险点处理
c42b79e 导出脚本
bb385f4 app 内导出/导入
51f8627 跨用户名迁移
1781e06 app 图标
```
