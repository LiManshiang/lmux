# LMUX — CodeBuddy Session Manager

## 阶段性开发总结 (v3.0)

**日期**: 2026-08-02
**状态**: 核心功能可用，终端可交互，支持多 session 切换不中断

---

## 项目概述

LMUX 是一个 macOS 原生 GUI 工具，用于管理多个 CodeBuddy Code 会话。左侧垂直侧边栏管理项目会话，右侧内嵌 SwiftTerm 终端直接运行 codebuddy-code。

---

## 架构

```
LMUX.app (SwiftUI + AppKit)
│
├── ContentView (HStack 左右分栏)
│   ├── SessionListView              左侧会话列表 (绿色圆点 = 已连接)
│   │   └── SessionRowView           点击选中 / 右键 Rename/Delete
│   │
│   └── SessionDetailView            右侧详情
│       ├── Header (会话名、目录、Kill 按钮)
│       └── PTYTerminalView (NSViewRepresentable)
│           └── LocalProcessTerminalView ← SwiftTerm
│               ├── Terminal (VT100 模拟器)
│               └── LocalProcess (forkpty → codebuddy-code)
│
├── ContentViewModel                状态管理 + TerminalManager 池
├── TerminalManager                 终端生命周期 (connect/detach/reattach/disconnect)
├── APIClient                       后端 HTTP 通信
│
└── Go Backend (独立进程)
    ├── HTTP API (localhost:19680 + token)
    ├── SQLite (会话注册表)
    └── CodeBuddy Scanner (扫描 ~/.codebuddy JSONL)
```

## 技术栈

| 层 | 技术 | 说明 |
|---|------|------|
| 终端渲染 | SwiftTerm (LocalProcessTerminalView) | 纯 Swift VT100 模拟器 + 原生 forkpty |
| PTY | forkpty (SwiftTerm LocalProcess) | 原生伪终端 |
| UI | SwiftUI + AppKit bridge | macOS 12+ |
| 后端 | Go 1.26 + SQLite | 会话元数据存储 |
| 进程 | codebuddy-code (前端直接启动) | 无 tmux 依赖，无 WebSocket relay |

## 关键设计决策

1. **TerminalManager 池化** — ContentViewModel 维护 `[sessionID: TerminalManager]` 字典，切换 session 时不销毁 TerminalManager
2. **detach/reattach 模式** — 切换 session 时 detach（不杀进程），切回时 reattach（复用已有 LocalProcessTerminalView）
3. **Go 后端纯元数据** — 后端只管理 session 的 CRUD 和元数据（SQLite），不管理进程生命周期
4. **无 tmux/WebSocket/UDS** — 经过多次方案迭代（WebSocket relay、UDS relay），最终回归最简单的 LocalProcessTerminalView 直接 forkpty

## 方案演进历史

| 版本 | 方案 | 结果 |
|------|------|------|
| v1 | LocalProcessTerminalView 直接 forkpty，视图销毁时杀进程 | 切换 session 丢失状态 |
| v2 | Go 后端管理进程 + WebSocket PTY relay | 输入延迟大，超时 |
| v3 | Go 后端管理进程 + Unix Domain Socket relay | 连接不稳定，TerminalView 渲染不可靠 |
| **v4 (当前)** | **LocalProcessTerminalView 直接 forkpty + 池化** | 流畅，切换不中断 |

## 项目文件结构

### Swift 前端 (`Sources/LMUX/`)

```
App.swift                                  @main 入口
Models/Session.swift                       Session, SessionSummary, SessionStatus
Network/APIClient.swift                    HTTP 客户端 (token 认证)
ViewModels/ContentViewModel.swift          状态管理 + TerminalManager 池
Views/
├── ContentView.swift                      主布局 (HStack 左右分栏)
├── SessionListView.swift                  会话列表 + SessionRowView
├── SessionDetailView.swift                会话详情 + 终端嵌入 + 连接管理
├── TerminalView.swift                     SwiftTerm NSViewRepresentable
└── NewSessionSheet.swift                  新建会话面板 (Browse 目录)
Utils/
└── TerminalManager.swift                  终端生命周期 (connect/detach/reattach/disconnect)
```

### Go 后端 (`backend-src/`)

```
cmd/cbsm/main.go                           入口
internal/
├── api/ {server, handlers, middleware}.go  HTTP API
├── session/ {types, store, manager}.go     会话持久化
├── codebuddy/scanner.go                    扫描 JSONL
└── config/config.go                        配置
```

---

## 已完成功能

### 核心
- [x] 左侧会话列表 + 点击选中 + 右键菜单
- [x] 右侧 SwiftTerm 内嵌终端 (LocalProcessTerminalView)
- [x] 点击 `+` 一键创建会话
- [x] 点击会话 → 自动连接终端
- [x] Kill 按钮终止会话
- [x] 会话切换保留进程状态 (detach/reattach)
- [x] 连接状态指示 (绿色圆点)
- [x] Go 后端 HTTP API (CRUD + token 认证)
- [x] 历史会话扫描恢复 (--restore)
- [x] 后端自动启动 (应用内)
- [x] macOS 12.0 最低部署

### 终端
- [x] SwiftTerm VT100 模拟 (forkpty)
- [x] 等宽字体 + 暗色主题
- [x] 键盘输入
- [x] `--permission-mode auto -y` 启动参数

### 后端
- [x] 会话 CRUD
- [x] Bearer token
- [x] SQLite
- [x] JSONL 扫描器

---

## 当前限制 / 待处理

| 优先级 | 问题 | 说明 |
|--------|------|------|
| 🔴 | 第一个新建 session 不显示 | onAppear/onChange 时序问题，已修复待验证 |
| 🟡 | 历史 session 需重新 spawn | 旧 session 的 codebuddy-code 进程已退出，选择时需重新创建 |
| 🟡 | 后端路径硬编码 | findCBSPaths 中路径写死 |
| 🟢 | SwiftTerm 本地依赖 | Package.swift 指向本地路径 |
| 🟢 | 鼠标滚轮 | 无滚动行为 |
| 🟢 | 新建会话目录 | 固定为 home dir |

---

## API 接口

| Method | Path | Auth | 说明 |
|--------|------|------|------|
| GET | /api/health | No | 健康检查 |
| GET | /api/sessions | Yes | 会话列表 |
| POST | /api/sessions | Yes | 创建 `{project_dir, name?}` |
| GET | /api/sessions/:id | Yes | 获取单个 |
| DELETE | /api/sessions/:id | Yes | 删除 |
| POST | /api/sessions/:id/rename | Yes | 重命名 `{name}` |
| POST | /api/restore | Yes | 恢复历史 |

---

## 构建和部署

```bash
# 构建
cd ~/Projects/lmux-app && make app

# 启动
~/Projects/lmux-app/.build/lmux.app/Contents/MacOS/lmux-backend --restore &
open ~/Projects/lmux-app/.build/lmux.app
```
