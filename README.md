# lmux

A macOS session manager for running **CodeBuddy** and **Claude Code** agents in
side-by-side embedded terminals.

> [中文说明 (Chinese)](README.zh-CN.md)

## Features

- **Multi-session sidebar** — create, rename, search, and switch between many
  terminal sessions, each with its own working directory.
- **Embedded agent terminals** — run CodeBuddy (`codebuddy-code`) or Claude
  (`claude`) directly in a SwiftTerm pane, with per-agent flags and trust
  handling.
- **Conversation resumption** — sessions remember their agent conversation and
  auto-resume it on reconnect; history lookup picks the most recently created
  conversation in a project.
- **Context & credit meter** — the sidebar shows each agent conversation's
  context-window usage (exact for CodeBuddy, estimated for Claude) and
  estimated credit spent.
- **Agent detection** — when an agent is launched inside a plain bash session,
  lmux detects it, marks the session, and surfaces its status.
- **Split terminal** — open a second terminal pane below the main one.
- **Keyboard shortcuts** — `⌘F` search, `⌘↑/⌘↓` switch sessions, `⌘K` stop,
  `⌘N` new.
- **Export / Import** — migrate all sessions and agent conversation data to
  another Mac via `Session → Export Sessions…` / `Import Sessions…`.

## Requirements

- macOS 12+
- Xcode command line tools (`xcode-select --install`)
- Go 1.26+ (backend)

## Dependencies

This project depends on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(MIT). The embedded terminal uses a **Swift 5.7 backport** of SwiftTerm; the
patch is included in this repository:

```sh
git clone https://github.com/migueldeicaza/SwiftTerm.git
cd SwiftTerm
git checkout 4acb12f   # upstream commit the patch is based on
git apply ../lmux-app/tools/patches/swiftterm-5.7-backport.patch
```

Then point `Package.swift`'s SwiftTerm dependency at your patched local clone.

## Build

```sh
cd lmux-app
swift build                 # frontend (LMUX + LMUXCore)
cd backend-src && go build -o ../backend/lmux ./cmd/cbsm   # backend
```

Run the development build with `swift run`, or package the app bundle:

```sh
cp -R .build/lmux.app /Applications/lmux.app
```

The app launches its embedded backend automatically; no daemon setup needed.

## Tests

```sh
cd lmux-app
swift test                  # LMUXCore unit tests (resolveSession, detection)
cd backend-src && go test ./...   # backend unit tests (session CRUD, find-session, context)
```

## Architecture

```
lmux-app/
  Sources/
    LMUX/          # macOS app (SwiftUI + SwiftTerm): views, view model, terminal
    LMUXCore/      # testable core library: AgentProvider protocol, per-agent
                   # providers (codebuddy/claude), session restore
    LMUXCoreTests/ # unit tests
  backend-src/     # Go backend: session store (SQLite), agent scanning,
                   # context/credit stats, REST API (port 19680)
  tools/
    export-lmux.sh # CLI export for migrating to another Mac
    patches/       # SwiftTerm 5.7 backport patch
```

Adding a new agent = a new `AgentProvider` implementation; the main flow
(connect, restore, detection) only depends on the provider protocol.

## License

[MIT](LICENSE)
