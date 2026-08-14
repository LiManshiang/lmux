# lmux

macOS 终端会话管理器，可在分屏的嵌入式终端中运行 **CodeBuddy** 和 **Claude Code** 智能体。

## 功能特性

- **多会话侧边栏** —— 创建、重命名、搜索、切换多个终端会话，每个会话有独立的工作目录。
- **嵌入式智能体终端** —— 直接在 SwiftTerm 面板中运行 CodeBuddy（`codebuddy-code`）或 Claude（`claude`），自动处理各自的启动参数与信任配置。
- **会话续接** —— 会话会记住自己的智能体对话，重连时自动恢复；历史查找优先选择项目中最晚创建的会话。
- **上下文与积分统计** —— 侧边栏显示每个会话的上下文窗口占用（CodeBuddy 精确、Claude 估算）以及估算积分消耗。
- **智能体检测** —— 在普通 bash 会话中启动智能体时，lmux 会自动识别、标记该会话并展示其运行状态。
- **分屏终端** —— 可在主终端下方打开第二个终端面板。
- **键盘快捷键** —— `⌘F` 搜索、`⌘↑/⌘↓` 切换会话、`⌘K` 停止、`⌘N` 新建。
- **导出 / 导入** —— 通过 `Session → Export Sessions…` / `Import Sessions…` 将全部会话与智能体对话数据迁移到另一台 Mac。

## 环境要求

- macOS 12+
- Xcode 命令行工具（`xcode-select --install`）
- Go 1.26+（后端）

## 依赖

本项目依赖 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）。嵌入式终端使用了 SwiftTerm 的 **Swift 5.7 backport** 补丁，补丁已包含在本仓库中：

```sh
git clone https://github.com/migueldeicaza/SwiftTerm.git
cd SwiftTerm
git checkout 4acb12f   # 补丁基于的上游提交
git apply ../lmux-app/tools/patches/swiftterm-5.7-backport.patch
```

然后将 `Package.swift` 中 SwiftTerm 的依赖指向打过补丁的本地克隆。

## 构建

```sh
cd lmux-app
swift build                 # 前端（LMUX + LMUXCore）
cd backend-src && go build -o ../backend/lmux ./cmd/cbsm   # 后端
```

运行开发版用 `swift run`，或打包 app：

```sh
cp -R .build/lmux.app /Applications/lmux.app
```

app 会自动启动内置后端，无需额外配置守护进程。

## 测试

```sh
cd lmux-app
swift test                  # LMUXCore 单元测试（resolveSession、进程检测）
cd backend-src && go test ./...   # 后端单元测试（会话 CRUD、find-session、上下文统计）
```

## 架构

```
lmux-app/
  Sources/
    LMUX/          # macOS 应用（SwiftUI + SwiftTerm）：视图、ViewModel、终端
    LMUXCore/      # 可测试的核心库：AgentProvider 协议、各智能体实现
                   # （codebuddy/claude）、会话恢复
    LMUXCoreTests/ # 单元测试
  backend-src/     # Go 后端：会话存储（SQLite）、智能体扫描、上下文/积分统计、
                   # REST API（端口 19680）
  tools/
    export-lmux.sh # 迁移到另一台 Mac 的命令行导出脚本
    patches/       # SwiftTerm 5.7 backport 补丁
```

新增一个智能体 = 实现一个 `AgentProvider`；主流程（连接、恢复、检测）只依赖 Provider 协议。

## 开源许可

[MIT](LICENSE)
