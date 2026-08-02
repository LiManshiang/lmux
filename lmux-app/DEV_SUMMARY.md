# CBSM — CodeBuddy Session Manager

## 阶段性开发总结 (v2.0-alpha)

**日期**: 2026-08-02  
**状态**: 核心功能可用，终端可交互

---

## 项目概述

CBSM 是一个 macOS 原生 GUI 工具，用于管理多个 CodeBuddy Code 会话。类似 cmux 的基础功能：左侧垂直标签栏管理项目会话，右侧内嵌 SwiftTerm 终端直接运行 codebuddy-code。

---

## 架构

```
CBSM.app (SwiftUI + AppKit)
│
├── ContentView (HStack 左右分栏)
│   ├── SessionListView              左侧会话列表 (绿色圆点 = 已连接)
│   │   └── SessionRowView           点击选中 / 右键 Rename/Delete
│   │
│   └── SessionDetailView            右侧详情
│       ├── Header (会话名、目录、Stop 按钮)
│       └── TerminalView (NSViewRepresentable)
│           └── LocalProcessTerminalView ← SwiftTerm
│               ├── Terminal (VT100 模拟器)
│               └── LocalProcess (forkpty → codebuddy-code)
│
├── ContentViewModel                状态管理 + connectedSessionId
├── TerminalManager                 终端生命周期 (connect/disconnect)
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
| 终端渲染 | SwiftTerm 1.15.0 (本地路径) | 纯 Swift VT100 模拟器 |
| PTY | forkpty (SwiftTerm LocalProcess) | 原生伪终端 |
| UI | SwiftUI + AppKit bridge | macOS 12+ |
| 后端 | Go 1.26 + SQLite | 会话元数据存储 |
| 进程 | codebuddy-code (直接启动) | 无 tmux 依赖 |

## 项目文件结构

### Swift 前端 (`~/Projects/cbsm-app/`)

```
Package.swift                              SPM 配置 (macOS 12, SwiftTerm 本地路径)
Info.plist                                 App 元数据
CBSM.entitlements                          权限 (沙盒已禁用)
Makefile                                   构建脚本
DEV_SUMMARY.md                             本文档

Sources/CBSM/
├── App.swift                              @main 入口
├── Models/
│   └── Session.swift                      Session, SessionSummary, SessionStatus
├── Network/
│   └── APIClient.swift                    HTTP 客户端 (token 认证)
├── ViewModels/
│   └── ContentViewModel.swift             状态管理 (会话CRUD, backend, connectedSessionId)
├── Views/
│   ├── ContentView.swift                  主布局 (HStack 左右分栏)
│   ├── SessionListView.swift              会话列表 + SessionRowView
│   ├── SessionDetailView.swift            会话详情 + 终端嵌入
│   ├── TerminalView.swift                 SwiftTerm NSViewRepresentable
│   └── NewSessionSheet.swift              新建会话面板 (备用)
└── Utils/
    └── TerminalManager.swift              终端生命周期 (启动/终止 codebuddy-code)
```

### Go 后端 (`~/Projects/cbsm/`)

```
cmd/cbsm/main.go                           入口
internal/
├── api/ {server, handlers, middleware}.go  HTTP API
├── session/ {types, store, manager}.go     会话持久化
├── codebuddy/scanner.go                    扫描 JSONL
└── config/config.go                        配置
bin/cbsm                                   编译好的二进制
com.cbsm.daemon.plist                      LaunchAgent
Makefile
```

---

## 已完成功能

### 核心
- [x] 左侧会话列表 + 点击选中 + 右键菜单
- [x] 右侧 SwiftTerm 内嵌终端
- [x] 点击 `+` 一键创建会话 (home dir, auto-named)
- [x] 新建/点击会话 → 自动连接终端
- [x] Stop 按钮停止会话
- [x] 会话切换保留历史 (`--session-id <uuid>`)
- [x] 连接状态指示 (绿色圆点)
- [x] Go 后端 HTTP API (CRUD + token 认证)
- [x] 历史会话扫描恢复
- [x] 后端自动启动 (LaunchAgent / 应用内)
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
| 🔴 | 鼠标滚轮 | 无滚动行为，需确定方案 |
| 🟡 | 进程终止 | Ctrl-C 可能不够优雅，需验证 codebuddy-code 是否正确退出 |
| 🟡 | 后端路径硬编码 | LaunchAgent 中 bin/cbsm 路径写死 |
| 🟡 | 新建会话目录 | 固定为 home dir，需支持选择目录 |
| 🟢 | SwiftTerm 本地依赖 | Package.swift 指向本地路径 `/Users/manshiangli/Projects/SwiftTerm` |

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

### 前置

```bash
brew install go
# SwiftTerm 从本地路径获取 (~/Projects/SwiftTerm)
```

### 构建

```bash
# Go
cd ~/Projects/cbsm
GOPROXY=https://goproxy.cn,direct go build -o bin/cbsm ./cmd/cbsm

# Swift
cd ~/Projects/cbsm-app
make app
```

### 启动

```bash
~/Projects/cbsm/bin/cbsm &
open ~/Projects/cbsm-app/.build/CBSM.app
```

### 另台机器部署 (macOS 12.5)

1. 安装 Go: `brew install go`
2. 克隆 SwiftTerm: `git clone https://github.com/migueldeicaza/SwiftTerm ~/Projects/SwiftTerm`
3. 编译 Go: `cd ~/Projects/cbsm && go build -o bin/cbsm ./cmd/cbsm`
4. 编译 Swift: `cd ~/Projects/cbsm-app && make app`
5. 启动: `~/Projects/cbsm/bin/cbsm & ; open ~/Projects/cbsm-app/.build/CBSM.app`

---

## 开发日志

### 2026-08-02 第二阶段

**完成:**
- 嵌入 SwiftTerm 替代 xterm.js/WKWebView
- 解决 SwiftTerm.TerminalView 命名冲突
- 降级 macOS 12.0 兼容性 (9 处修改)
- 移除 tmux 依赖，直接 forkpty + codebuddy-code
- 修复 `node: No such file or directory` (PATH 继承)
- 会话历史持久化 (`--session-id`)
- 一键快速创建 (无对话框)
- 修复 JSON 解码错误 (移除 tmux 字段)
- 连接状态指示圆点 (绿色/灰色)
- `--permission-mode auto -y` 启动参数
- 回退 SwiftTerm 为本地路径依赖 (GitHub 不可达时)

### 技术决策记录

1. **不用 tmux** — 简化架构，直接 forkpty。代价：切换标签页会终止进程。
2. **不用 xterm.js** — 资源加载在 .app bundle 中有安全限制，不可靠。
3. **不用 Drawin/git fetch** — SPM 缓存 + 本地路径作为兜底方案。
4. **Status 不再由后端维护** — 改用 `connectedSessionId` 反映前端实际连接状态。

---

## 下一步建议

1. **鼠标滚轮方案** — 确定是传事件到 codebuddy-code 还是保留终端回滚
2. **新建会话时选目录** — 快速创建用 home dir，右键加 "New in folder..."
3. **多项目目录** — 自动检测 git 仓库或让用户配置
4. **通知/highlight** — agent 需要关注时高亮标签
5. **快捷键** — Cmd+N, Cmd+W 等
6. **分屏支持** — 同一标签页内多个终端
