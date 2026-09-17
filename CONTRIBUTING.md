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

The app must ship its SwiftPM resource bundles in `Contents/Resources/`, **and**
the frontend has to be built with swiftbuild. Both matter, because SwiftPM
generates two shapes of `Bundle.module` accessor: swiftbuild probes
`Bundle.main.resourceURL` (Contents/Resources), while the deprecated native
build system probes `Bundle.main.bundleURL` — the .app itself. A bundle cannot
live there instead: codesign seals only `Contents/` and refuses a bundle with
"unsealed contents present in the bundle root". Either failure leaves the
generated accessor trapping with `fatalError` before `ghostty_init`, so the app
dies the first time a terminal session connects.

`assemble_bundle` in `lmux-app/Makefile` copies the bundles, builds with
`--build-system swiftbuild` (Swift 6.2/6.3 need the flag; 6.4 defaults to it),
and fails the build if the layout or the accessor is wrong. **Compiling and
running the unit tests does not catch any of this** — check a packaged or
published app instead:

```sh
bash lmux-app/tools/check-app-bundles.sh .build/lmux.app
bash tools/verify-release.sh v1.0.283
```

## Code style

- Swift: match the existing style (4 spaces, doc comments on public API).
- Go: standard `gofmt`.
- Commit messages: short imperative subject; details in the body.
