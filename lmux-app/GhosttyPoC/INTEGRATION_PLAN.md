# libghostty 正式集成方案（TerminalManager 适配 + 双后端切换）

> 分支：`poc/libghostty`（PoC 已通过，见 `GhosttyPoC/README.md`）
> 本文档基于 PoC 验证结果，设计把 GhosttyKit（libghostty）作为 lmux 的可选渲染后端，
> 与 SwiftTerm 并行，支持运行时切换。

## 1. 目标与约束

- **目标**：用一个 `TerminalBackend` 协议抽象渲染+PTY 能力，SwiftTerm 与 libghostty
  各实现一份；`TerminalManager` 只依赖协议，不依赖具体渲染库。
- **约束**：
  - GhosttyKit 要求 **macOS 13+**；lmux 当前 `LSMinimumSystemVersion=12.0`。
  - 不得破坏现有 SwiftTerm 路径（作为默认/降级后端）。
  - 保留全部现有功能：agent 启动/恢复、idle 检测、OSC 通知、主题实时切换、拖放输入。

## 2. 现状：TerminalManager 的 SwiftTerm 依赖点

| 能力 | SwiftTerm 用法（现状） | 对应 GhosttyKit API |
|---|---|---|
| 渲染视图 | `LocalProcessTerminalView`（NSView+PTY 一体） | `TerminalSurfaceView(context:)`（SwiftUI）或 `AppTerminalView`（NSView） |
| spawn 进程 | `view.startProcess(executable:args:environment:currentDirectory:)`（forkpty） | `.exec` 后端（libghostty 内部 PTY+spawn）或 `.inMemory`+宿主 PTY |
| PID | `view.process.shellPid` | `TerminalView.foregroundPid`（public） |
| 进程退出 | `processDelegate.processTerminated` | `TerminalViewState.onClose(processAlive:)` / `terminalDidClose` |
| 首次输出 | `OutputAwareTerminalView.dataReceived` 覆盖 | 需替代（见 §7） |
| idle 活动信号 | `dataReceived` 每次触发 | 需替代（见 §7） |
| OSC 777/9 通知 | `parser.oscHandlers[777/9]` | `terminalDidRequestDesktopNotification(title:body:)`（原生 action） |
| 标题 | `setTerminalTitle` | `terminalDidChangeTitle` |
| cwd | `hostCurrentDirectoryUpdate` | `terminalDidChangeWorkingDirectory` |
| 主题 | `nativeForegroundColor/...` + `installColors` | `TerminalController.setTerminalConfiguration` / `setTheme` |
| scrollback | `changeScrollback(n)` | config `scrollback-limit` |
| 发送输入 | `view.send(txt:)` | `TerminalSurface.sendText(_:)` |
| 拖放 | `TerminalContainerView` + `mgr.sendInput` | 不变（仍在宿主层） |
| 容器 | `PTYTerminalView` NSViewRepresentable | 保留，内部换后端视图 |

## 3. 目标架构

```
ContentViewModel ── terminalManager(for:) ──> TerminalManager
                                                  │ 仅依赖协议
                                                  ▼
                                      ┌─ TerminalBackend (protocol) ─┐
                                      │                              │
                                 SwiftTermBackend               GhosttyBackend
                                 (现有逻辑迁移)                 (TerminalSurfaceView)
                                      │                              │
                                   SwiftTerm                      GhosttyKit
```

- **`TerminalBackend`**：定义渲染视图、进程生命周期、输入输出、回调、主题、scrollback。
- **`TerminalManager`**：持有 `backend: TerminalBackend`，所有现有逻辑（agent 检测、idle
  定时器、SessionRestore、连接决策）不变，只把 SwiftTerm 直调换成 backend 方法。
- **切换**：`UserDefaults.standard.string(forKey: "terminalRenderer")`
  （`"swiftterm"` 默认 / `"ghostty"`），`TerminalBackendFactory` 按值创建。

## 4. TerminalBackend 协议（草案）

```swift
@MainActor
protocol TerminalBackend: AnyObject {
    // 渲染视图（嵌入 PTYTerminalView 容器）
    var view: NSView { get }

    // 进程
    var processPID: Int32 { get }
    var isProcessRunning: Bool { get }

    // 生命周期（返回 false = 启动失败，宿主转 connectErrorMessage）
    @discardableResult
    func startAgent(executable: String, args: [String], env: [String], cwd: String) -> Bool
    @discardableResult
    func startBash(cwd: String, env: [String]) -> Bool
    func terminate()
    /// detach 不杀进程；视图实例必须保活（进程才能存活）
    func detach()
    func reattach()

    // 输入
    func sendInput(_ text: String)

    // 回调（TerminalManager 注入）
    var onFirstOutput: (() -> Void)? { get set }
    var onActivity: (() -> Void)? { get set }
    var onProcessExit: (() -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
    var onNotify: ((String, String) -> Void)? { get set }   // title, body

    // 主题 / 配置
    func applyTheme(_ theme: TerminalTheme)
    func setScrollback(_ lines: Int)
}
```

### 4.1 SwiftTermBackend
- 迁移现有 `connect`/`connectBash` 的视图构造、`OutputAwareTerminalView`、
  `Delegate`（processTerminated、setTerminalTitle、hostCurrentDirectoryUpdate）逻辑。
- `view` 返回 `LocalProcessTerminalView`，`PTYTerminalView` 的 live-resize stretch 逻辑
  照搬现有 `Coordinator`。

### 4.2 GhosttyBackend
- 持有一个 `TerminalViewState`（`@StateObject`）+ `TerminalController`（app 级，复用共享实例）。
- `view` 用 `AppTerminalView`（NSView，非 SwiftUI 封装），与 `PTYTerminalView` 容器兼容，
  且 `foregroundPid`/`ttyName` 是 public 可读。
- spawn 通过 `.exec` 后端：`TerminalSurfaceOptions(backend: .exec, workingDirectory:,
  envVars:, command:)`。
- 主题：把 lmux `TerminalTheme` 桥接为 `TerminalConfiguration`（hex 字符串），调
  `controller.setTerminalConfiguration(...)`（内部 `ghostty_surface_update_config`，
  实时生效，无需重建）。

## 5. PTYTerminalView 适配

现有 `PTYTerminalView(manager:)` 的 `updateNSView` 逻辑：
- `guard let terminal = manager.terminalView, manager.isConnected`
- 挂 subview / live-resize stretch / snapToFinal

改为：
- `guard let terminal = manager.backend?.view, manager.isConnected`
- live-resize stretch/snap 对 `AppTerminalView` 同样适用（它是 NSView，有 layer）。
- 保持 `.id("main-terminal-\(sid)")` 稳定 id 不变，防止 NSView 重建（K3 教训）。

## 6. 进程生命周期映射

| 场景 | SwiftTerm | Ghostty（.exec） |
|---|---|---|
| connect | `startProcess` → shellPid>0 | `ghostty_surface_new` 内部 spawn；`foregroundPid` 可用 |
| disconnect/杀 | `view.process.terminate()` | `backend.terminate()` → `ghostty_surface_close`（kill PTY 进程组） |
| detach 保活 | 不调 terminate，保留 view 实例 | **同样保留 `AppTerminalView` 实例**；不销毁 surface |
| reattach | `reattach()` 标记连接 | 同上 |
| 退出检测 | `processTerminated` | `onClose(processAlive:)` |
| PID | `shellPid`（稳定 shell PID） | `foregroundPid`（前台进程组，shell 空闲时即 shell PID） |

> ⚠️ **PID 语义差异**：`foregroundPid` 是 `tcgetpgrp(pty)`，agent 运行时返回的是
> agent 的 PID 而非 shell PID。TerminalManager 的 agent 检测逻辑以 `processPID` 为根
> 遍历子孙进程。适配方式：`.exec` 后端下把 shell PID 记为 `processStartPid`（首次
> `foregroundPid`），后续检测沿用该根；或用 `ttyName` 经 `ps -t` 反查 shell PID。
> 这是实现时需实测的点。

## 7. idle / 首次输出检测（关键差异）

SwiftTerm 通过 `dataReceived`（每次 PTY 输出）驱动 `onFirstOutput` 与 `onActivity`。
Ghostty `.exec` 后端宿主拿不到字节流。替代方案：

- **首选（轻量）**：`.exec` 后端 + 轮询 `ghostty_surface_read_text`（viewport 文本）。
  后端内部 1s 定时器 hash 比对：
  - 首次读到非空文本 → `onFirstOutput`
  - 文本 hash 变化 → `onActivity`
  与现有 2s idle 定时器 + 3s 阈值完全兼容，开销可控。
- **备选（精确）**：`.inMemory` 后端 + 宿主自管 PTY（forkpty + posix_spawn）。
  宿主在 `InMemoryTerminalSession.write` 闭包收到终端输出字节 → 天然得到
  onFirstOutput/onActivity；但需自写 PTY 管理层，工作量较大。
- 推荐先用**首选**方案落地，若 idle 精度不满足再切备选。

> OSC 777/9 通知无需轮询：Ghostty 原生解析后回调
> `terminalDidRequestDesktopNotification(title:body:)`，直接桥到 `onNotify`。

## 8. 主题桥接

lmux `TerminalTheme`（8 个预设）→ Ghostty `TerminalConfiguration`：

| lmux | Ghostty builder |
|---|---|
| `foreground` | `withForeground(hex)` |
| `background` | `withBackground(hex)` |
| `selection` | `withSelectionBackground(hex)` |
| `cursor` | `withCursorColor(hex)` |
| `ansi[16]` | `withPalette(i, color: hex)` |

- 颜色格式：lmux 存 `(Double, Double, Double)`（0...1），转 `"#RRGGBB"`（0...255）。
- 实时切换：`PreferencesView` 点击 → 现有 `.lmuxTerminalThemeChanged` 通知 →
  `TerminalManager.applyTheme` → 分发给 backend：
  - SwiftTerm：现有直接设 view 属性
  - Ghostty：`controller.setTerminalConfiguration(桥接配置)`
- **注意**：Ghostty 主题是「配置」而非「视图属性」，`TerminalController` 建议 app 级单例
  （`TerminalController.shared` 已存在），避免每个 manager 一份 config 解析开销。

## 9. 后端切换

- `UserDefaults` 键 `terminalRenderer`：`"swiftterm"`（默认）| `"ghostty"`。
- `TerminalBackendFactory.make()`：读取并按 key 返回对应 backend。
- PreferencesView 加一个「Terminal Renderer」选择（SegmentPicker）：
  - 切换只影响**新连接**的会话；已运行会话保持原后端（避免杀进程）。
- 若 GhosttyKit 不可用（macOS < 13）：`factory` 回退 SwiftTerm，设置项置灰并提示。

## 10. 平台要求决策（需确认）

- **方案 A：全 app 升 macOS 13+**（推荐）。放弃 macOS 12 支持，主包直接依赖
  GhosttyKit，双后端同一 target 内条件/运行时切换。改动最小、可维护性最好。
  - macOS 12 已于 2024 年 EOL，2026 年的目标用户几乎都在 13+。
- 方案 B：保持 macOS 12，Ghostty 后端拆独立 target/动态库，运行时 dlopen。
  - SPM 不支持「可选依赖」；需预编译 dylib + `dlopen`/`#if canImport`，复杂且脆弱。
- 方案 C：仅作为独立二进制（现状 PoC），不集成进主 app。不符合本方案目标。

## 11. 实施步骤

1. **协议落地**：新建 `TerminalBackend.swift`（协议 + Factory + UserDefaults 开关）。
2. **SwiftTermBackend**：从 `TerminalManager` 迁移视图构造/回调/主题/输入，行为零变化。
3. **TerminalManager 改造**：`terminalView` → `backend`；`connect/connectBash/disconnect/
   detach/reattach/sendInput/applyTheme` 全改走协议；保留 agent 检测、idle、restore。
4. **GhosttyBackend（exec + 轮询）**：实现协议；`.exec` spawn、通知桥、
   viewport 轮询 idle、主题桥接、PID 适配（实测 foregroundPid 语义）。
5. **PTYTerminalView**：`manager.terminalView` → `manager.backend?.view`；保持 id/容器逻辑。
6. **PreferencesView**：加 renderer 选择；主题切换分发双后端。
7. **测试**：SwiftTerm 回归（现有 12 个 LMUXCore 测试 + 手动连接 codebuddy/claude）；
   Ghostty 路径验证：新会话、恢复、分屏、idle 状态、OSC 通知、主题实时切换、拖放。
8. **提交**：分步提交到 `poc/libghostty`（或新 `feature/ghostty-renderer`）。

## 12. 风险

| 风险 | 缓解 |
|---|---|
| `foregroundPid` 语义与 shellPid 不同 | §6 适配：首见 PID 记为根，或 `ttyName` 反查 |
| viewport 轮询 idle 有 1s 延迟 | 阈值 3s > 轮询 1s，可接受；必要时切 inMemory |
| GhosttyKit API 未冻结 | 上游 pinned 版本 + 本地 vendor；升级时回归测试 |
| macOS 12 用户流失（若升 13） | 用户确认；12 已 EOL |
| .exec 后端无法拿字节流 | inMemory+宿主 PTY 为备选路线 |
| Surface 随 view 释放杀进程 | detach 必须保活 `AppTerminalView` 实例（与现状一致） |

## 13. 验证清单（Ghostty 后端）

- [ ] 新建 session → codebuddy 启动 → 输入 hello → 上下文百分比增长
- [ ] 新建 session → claude 启动 → 恢复对话
- [ ] 切换 session → 状态正确切换 running/idle（轮询 idle）
- [ ] 分屏 Terminal 打开/关闭
- [ ] OSC 通知（任务完成）
- [ ] 主题实时切换（Preferences → Theme，不重启）
- [ ] 拖放文件插入路径
- [ ] detach 后进程存活，reattach 正常
- [ ] 退出 app → 重启 → session 恢复

---

**待确认**：§10 平台要求（A 升 13 / B 保持 12+dlopen / C 不集成）。
