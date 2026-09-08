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
- **Cross-device session sync** — pinned sessions sync incrementally as
  `.lmuxsession` bundles through any folder that syncs between your Macs
  (iCloud Drive, Syncthing, …); raw agent JSONL is mirrored alongside. Imports
  localize recorded paths to the local project directory, full exports are
  never appended twice, and two-sided edits surface a keep-local / use-remote
  conflict dialog instead of silently overwriting.
- **Open In menu** — right-click a session to open it in a new window or jump
  to its working directory in Finder.

## Requirements

- macOS 13+ (Ghostty GPU rendering backend), or macOS 12+ with the SwiftTerm
  backend (Intel x86_64 builds via `make app-x86`)
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

One code line, two app products (same Swift sources; Ghostty-specific code is
behind `#if canImport(GhosttyTerminal)`):

```sh
cd lmux-app
make test                   # unit tests (arch -arm64; avoids Rosetta x86 .build pollution)
make app                    # lmux.app    — Ghostty renderer, macOS 13+ (.build/lmux.app)
make app-st                 # lmux-st.app — SwiftTerm renderer, macOS 12 (.build-st/lmux-st.app)
make app-x86                # lmux-st.app — x86_64 Intel + SwiftTerm + macOS 12
```

- `make app-st` temporarily swaps `Package.st.swift` over `Package.swift`
  (trap-restored) and builds into a separate `.build-st` scratch path, so the
  two variants never pollute each other.
- The backend binary is a **build product, not tracked in git**: every app*
  target rebuilds it via `go build` (falls back to an existing `backend/lmux`
  when Go is missing). New machines need Go installed.
- Run the development build with `swift run`, or install a bundle:

```sh
cp -R .build/lmux.app /Applications/lmux.app
```

The app launches its embedded backend automatically; no daemon setup needed.

## Tests

```sh
cd lmux-app
make test                   # frontend LMUXCore unit tests (77 cases, arm64)
cd backend-src && go test ./...   # backend unit tests (session CRUD, find-session,
                                  # session-valid fast path, import/export)
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
