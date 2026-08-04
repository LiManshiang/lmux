# lmux 1.0.6 — 进展文档

**日期:** 2026-08-04
**分支:** 1.0.6（开发）+ fix/crash-issues（崩溃修复，未合并）
**版本:** 1.0.39
**Git 钩子:** pre-commit 自动升级小版本号

---

## 已完成的修复/功能

### 1.0.6 阶段

| # | 简述 | 提交 | 文件 |
|---|------|------|------|
| 1 | Agent 检测（pgrep 子进程） | b425a6f | TerminalManager.swift |
| 2 | LaunchMode 追踪（bash/agent） | b425a6f | SessionRestore.swift |
| 3 | Restore 时从后端回退 cbcSessionID | ad3e5b6 | ContentViewModel.swift |
| 4 | Polling 优化（不再无条件重赋值 selectedSession） | d739ce1 | ContentViewModel.swift |
| 5 | SessionDetailView 移除条件分支（PTYTerminalView 位置固定） | 多次 | SessionDetailView.swift |
| 6 | Scrollback 降至 50K 行 | 6c5926e | TerminalManager.swift |
| 7 | Split pane overlay 方式实现 | 多次 | SessionDetailView.swift |
| 8 | Split ratio 控制 terminal 高度（不可见时高度 0） | 7809ed4 | SessionDetailView.swift |
| 9 | 性能: isIdle 节流（2s 而非每次 data chunk） | c358f6d | TerminalManager.swift |
| 10 | 闪退修复: SwiftTerm 回调 dispatch 到 main queue | 8cbb0d4 | TerminalManager.swift |
| 11 | 合并 perf/optimize-v1 性能优化 | 0e1e863 | 多文件 |
| 12 | 新建 session 直接启动 agent 而非 bash | 8d14476 | SessionDetailView.swift, ContentViewModel.swift |
| 13 | 侧边栏版本号 + 自动 bump | 2689ed4 | Version.swift, bump-version.sh, .githooks/ |

### fix/crash-issues 阶段（未合并到 1.0.6）

| # | 简述 | 提交 | 文件 |
|---|------|------|------|
| 14 | **行为修正**: 新建 session 无历史 → 进 bash（非 agent）；有历史 → 跟随历史进 agent | da95ae3 | SessionDetailView.swift, ContentViewModel.swift |
| 15 | Restore 仅对 agent 模式做 JSONL 扫描（bash 模式不再被历史会话劫持） | da95ae3 | ContentViewModel.swift |
| 16 | DispatchIO 双重 close 防护（closeBackendIO 单次关闭）+ retryBackend 先关 IO 再 kill（防 EV_VANISHED） | d837686 | ContentViewModel.swift |
| 17 | connect/connectBash 启动失败检测（executable 存在 + shellPid>0）+ onConnectError 上抛 UI | b997b7a | TerminalManager.swift, ContentViewModel.swift |
| 18 | bash scrollback 1M→200K 行；detach() 停止 agent 检测 timer | b997b7a | TerminalManager.swift |
| 19 | SessionRowView 用 terminalManagerIfExists 只读查询（不再为每行建空壳 manager） | 0ffd56c | SessionListView.swift, ContentViewModel.swift |
| 20 | SessionRestore.loadAll() 走 ioQueue + 内存缓存（main 不再同步读盘） | 0ffd56c | SessionRestore.swift |
| 21 | refreshSessions 比较整个数组内容（status/pid 变化可刷新） | 0ffd56c | ContentViewModel.swift |
| 22 | K3: split pane PTYTerminalView 加 `.id()` 稳定 NSView 身份 | 2f708b1 | SessionDetailView.swift |

## 已知问题

| # | 描述 | 状态 | 分析 |
|---|------|------|------|
| K1 | `/skills` 命令导致对话重载 | 已知，不可修复 | Agent 层面行为（CSI 3 J 尝试过，SwiftTerm patch 尝试过，都不是根因） |
| K2 | 窗口缩放导致对话重载 | 已知，标准行为 | SIGWINCH → source → codebuddy 重绘。Terminal.app 同样有，只是速度快不明显 |
| K3 | Split pane toggle 可能导致 NSView 重建 | ✅ 已修复 | `.id("main/split-terminal-\(sid)")` 稳定身份（fix/crash-issues 2f708b1） |

## macOS 12.5 (Intel) 兼容性

- 代码层面**完全兼容**：部署目标 `.macOS(.v12)`，无 macOS 13+ 专属 API（已全量 grep）
- 目标机为 **Intel x86_64**；`swift build --arch x86_64` 交叉编译可行
- **坑**：后端 `go-sqlite3` 需 CGO。交叉编译 amd64 必须 `CGO_ENABLED=1` + `CC="clang -target x86_64-apple-macos12.0 -isysroot $(xcrun --show-sdk-path)"`，否则编出 stub 后端（启动即崩）
- 交付物：`lmux-app/.build/lmux.app`（x86_64 前端 + x86_64 CGO 后端，已 ad-hoc 签名，21MB）
- 12.5 原生编译：Xcode 14 (Swift 5.7) + Go；`Package.swift` 引用绝对路径 `/Volumes/Developer/CodeBuddy/Projects/lmux/SwiftTerm`，**换路径需改相对路径** `../SwiftTerm`；SwiftTerm 含本地 backport commit（44339a2），须随目录拷贝

## 修改的核心文件

```
lmux-app/Sources/LMUX/
  Utils/
    TerminalManager.swift    — agent 检测 + 闪退修复 + 性能优化 + 启动失败检测 + scrollback
    SessionRestore.swift     — LaunchMode 追踪 + ioQueue 缓存读
    Version.swift            — 版本号定义（1.0.39）
  Views/
    SessionDetailView.swift  — split pane overlay + 启动路由（bash/agent）+ .id()
    SessionListView.swift    — 只读 manager 查询
    ContentView.swift        — 侧边栏版本号显示
    TerminalView.swift       — frame 更新优化
  ViewModels/
    ContentViewModel.swift   — restore 路由 + polling 优化 + DispatchIO 防护 + 数组比较
  Models/
    Session.swift            — AgentType 枚举
  Network/
    APIClient.swift          — 性能优化（perf 分支）
  Info.plist                 — About 版本号

bump-version.sh             — 版本号升级脚本
.githooks/pre-commit        — 自动升级版本号
```

## 下次继续

1. **合并 fix/crash-issues → 1.0.6**（用户确认后再合）
2. 在 Intel macOS 12.5 真机跑修复版（Swift ABI 理论兼容，需真机验证；验证 `/skills`、窗口缩放、split pane）
3. 12.5 机器上若改代码路径，改 `Package.swift` 为相对路径 `../SwiftTerm`
4. 其他中低风险项（可选）：`refreshSessions` 数组比较已做；backend/lmux 二进制为构建产物，避免提交

## 分支状态

```
master ─── 最终稳定代码
1.0.6  ─── 开发主线（bash 修复已合入 da95ae3）
fix/crash-issues ─── 崩溃/稳定性修复（9 项，d837686..2f708b1），未合并
perf/optimize-v1 ─── 性能优化（已合并到 1.0.6）
```
