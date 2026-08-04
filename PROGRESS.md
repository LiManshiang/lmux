# lmux 1.0.6 — 进展文档

**日期:** 2026-08-04
**分支:** 1.0.6
**版本:** 1.0.33
**Git 钩子:** pre-commit 自动升级小版本号

---

## 已完成的修复/功能

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

## 已知问题

| # | 描述 | 状态 | 分析 |
|---|------|------|------|
| K1 | `/skills` 命令导致对话重载 | 已知，不可修复 | Agent 层面行为（CSI 3 J 尝试过，SwiftTerm patch 尝试过，都不是根因） |
| K2 | 窗口缩放导致对话重载 | 已知，标准行为 | SIGWINCH → source → codebuddy 重绘。Terminal.app 同样有，只是速度快不明显 |
| K3 | Split pane toggle 可能导致 NSView 重建 | 待修复 | View 在不同分支间切换 → SwiftUI 重建 NSView。加 `.id()` 可解 |

## 修改的核心文件

```
lmux-app/Sources/LMUX/
  Utils/
    TerminalManager.swift    — agent 检测 + 闪退修复 + 性能优化
    SessionRestore.swift     — LaunchMode 追踪
    Version.swift            — 版本号定义（1.0.33）
  Views/
    SessionDetailView.swift  — split pane overlay + agent 直接启动
    ContentView.swift        — 侧边栏版本号显示
    TerminalView.swift       — frame 更新优化
  ViewModels/
    ContentViewModel.swift   — restore 路由 + polling 优化
  Models/
    Session.swift            — AgentType 枚举
  Network/
    APIClient.swift          — 性能优化（perf 分支）
  Info.plist                 — About 版本号

bump-version.sh             — 版本号升级脚本
.githooks/pre-commit        — 自动升级版本号
```

## 下次继续

1. **K3**: Split pane toggle NSView 重建 — 在 `PTYTerminalView` 两分支加 `.id("main-terminal")` 保持 NSView 标识
2. 性能: 验证 `/skills` 和窗口缩放的性能改善（应该快很多了）
3. 测试新建 session → agent 直接启动是否正常

## 分支状态

```
master ─── 最终稳定代码
1.0.6  ─── 当前开发分支（所有修复在本分支）
perf/optimize-v1 ─── 性能优化（已合并到 1.0.6）
```
