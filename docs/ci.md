# CI and TestFlight from GitHub Actions

Two workflows in `.github/workflows/`:

| Workflow | When | What |
|---|---|---|
| `ci.yml` (CI) | push to `main`, every pull request, by hand. Changes that only touch `*.md`, `docs/` or `.scratch/` are skipped. | `npm test` in `Extensions/SafariExtension` (Ubuntu, Node 24). On the `xcode-27` runner: `swift test` in `Packages/DeepwellCore`, `xcodegen generate`, then unsigned builds of the Mac app, DeepwellMobile and DeepwellUI (iOS Simulator). |
| `release.yml` (Release to TestFlight) | after CI succeeds on a **push** to `main` (not on pull requests), or by hand (Actions > Release to TestFlight > Run workflow) | For `mac` and `ios` in parallel: `scripts/release.sh --platform <p> --build <N> --sign-with-api-key`, which archives, exports, checks, validates, uploads and waits for processing (VALID or the rejection). |

Runner: `xcode-27` is GitHub's Xcode 27 image (macOS 27, Apple Silicon, generally available since 2026-10-15). The
code needs the iOS 26+ SDK. The `macos-26`/`macos-latest` images default to Xcode 26.x. The first run's "Toolchain"
step prints the Xcode version in use.

## Build numbers

CI uses `BUILD_NUMBER_OFFSET` (repository variable, default 100) + the release workflow's run number, for both
platforms, and never edits `project.yml` (`release.sh --build N`). App Store Connect wants a higher number than any
earlier upload of the same version, so:

- before the first CI release, the highest uploads were Mac 9 and iOS 10, so 100 + run number is above both;
- once CI has published, a local `scripts/release.sh` would use `project.yml`'s number (10, 11…), which is lower and
  would be rejected. Publish from CI only, or set `CURRENT_PROJECT_VERSION` above the last CI number before a local
  upload. `build/release/uploaded*` record local uploads only.

## One-time setup (the repository owner)

Repository **secrets** (Settings > Secrets and variables > Actions):

- `ASC_KEY_ID`, `ASC_ISSUER_ID`: the App Store Connect API key's id and the issuer id.
- `ASC_KEY_P8_BASE64`: the key's `.p8`, base64-encoded, e.g. `base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8_BASE64`.

Repository **variables**: `DEVELOPMENT_TEAM` = `NDMG62GXZA`. Optionally `BUILD_NUMBER_OFFSET`.

The key must have the **Admin** role. A runner has no Xcode account, so the key does the signing too
(`--sign-with-api-key` passes `-authenticationKey*` to `archive` and `-exportArchive`), and cloud-managed distribution
certificates need Admin. The local flow deliberately signs through the Xcode sign-in instead, because an App Manager
key gets "Cloud signing permission error". If the existing key isn't Admin, create one in App Store Connect > Users and
Access > Integrations and use its ids for these secrets.

Until all four are set, the release job logs a warning and publishes nothing; CI still runs.

## Cost

The repository is private, so Actions usage is billed. A macOS runner costs $0.062/min, and GitHub Free includes $12 of
compute a month (about 190 macOS minutes). A CI run is roughly 10–20 macOS minutes. A release runs two macOS jobs, each
archiving, exporting and then waiting up to 20 minutes for processing, so expect 30–60 minutes per push to `main`.
Without a payment method, runs stop when the allowance is used up.

## Not verified yet

Nothing here has run on GitHub. Not yet confirmed: that the `xcode-27` label schedules as the changelog says, that the
key signs (Admin role) with automatic signing on a runner (development profiles for the archive, cloud distribution
certificates for the export), and Mac and iOS uploads from CI. `--build` was checked locally: an iOS export-only run
with `--build 777` gave 777 for the app and both extensions, and `project.yml` stayed unchanged.
