# Contributing to lmux

Thanks for your interest! lmux is a native macOS app (SwiftUI frontend +
Go backend) for running CodeBuddy Code and Claude Code agents side by side.

## Development setup

```sh
git clone https://github.com/LiManshiang/lmux.git
cd lmux

# Local Swift packages expected at repo root (see README "Build from source"):
#   ../SwiftTerm       — upstream 4acb12f + tools/patches/swiftterm-5.7-backport.patch
#   ../libghostty-spm  — upstream Lakr233/libghostty-spm @ 31884f5

cd lmux-app
make app        # build lmux.app into .build/lmux.app
make test       # frontend LMUXCore unit tests (arm64)
cd backend-src && go test ./...   # backend tests
```

## Submitting changes

1. Fork & create a feature branch (`feat/...` or `fix/...`).
2. Keep the frontend and backend test suites green:
   `make test` and `go test ./...`.
3. Open a PR with a short description of the user-visible behavior change.

## Good first issues

- Add a new agent provider (implement the `AgentProvider` protocol in
  `lmux-app/Sources/LMUXCore/AgentProvider.swift`) — see the existing
  codebuddy/claude providers for the shape.
- Improve docs and translations (README.zh-CN.md parity is tracked).

## Packaging

The app must ship its SwiftPM resource bundles. `Contents/Resources/` needs
`GhosttyKit_GhosttyTerminal.bundle` and `SwiftTerm_SwiftTerm.bundle`, or the
generated `Bundle.module` accessor traps with `fatalError` before
`ghostty_init` and the app dies the first time a terminal session connects.

`assemble_bundle` in `lmux-app/Makefile` copies them and fails the build when
there are none; the release workflow asserts they are present before packaging.
**Compiling and running the unit tests does not catch this** — either launch the
app or inspect its `Contents/Resources` before shipping. To check a published
release:

```sh
bash tools/verify-release.sh v1.0.274
```

## Code style

- Swift: match the existing style (4 spaces, doc comments on public API).
- Go: standard `gofmt`.
- Commit messages: short imperative subject; details in the body.
