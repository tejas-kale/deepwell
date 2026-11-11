# CI on GitHub Actions

`.github/workflows/ci.yml` runs the tests. Publishing is not done by CI: releases go out from the Mac with
`scripts/release.sh` (docs/install.md).

| When | What |
|---|---|
| Push to `main`, every pull request, or by hand (Actions > CI > Run workflow). Changes that only touch `*.md`, `docs/` or `.scratch/` are skipped. | `npm test` in `Extensions/SafariExtension` (Ubuntu, Node 24). On the `xcode-27` runner: `swift test` in `Packages/DeepwellCore`, `xcodegen generate`, then unsigned builds (`CODE_SIGNING_ALLOWED=NO`) of the Mac app, DeepwellMobile and DeepwellUI (iOS Simulator). |

No secrets are needed: nothing is signed or uploaded, and `Config/Local.xcconfig` is optional (`#include?`).

Runner: `xcode-27` is GitHub's Xcode 27 image (macOS 27, Apple Silicon, generally available since 2026-10-15). The
code needs the iOS 26+ SDK. The `macos-26`/`macos-latest` images default to Xcode 26.x. The "Toolchain" step prints
the Xcode version in use.

## Cost

The repository is private, so Actions usage is billed. A macOS runner costs $0.062/min, and GitHub Free includes $12 of
compute a month (about 190 macOS minutes). A run is roughly 10–20 macOS minutes; the npm job on Ubuntu is negligible.
Without a payment method, runs stop when the allowance is used up.

## Not verified yet

The workflow has not run on GitHub yet. The first run confirms the `xcode-27` label and the Xcode version.
