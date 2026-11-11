# Installing Deepwell (TestFlight)

Deepwell installs on every Mac (and later iPhone/iPad, ticket 15) from TestFlight. `scripts/release.sh` archives
the app with its Safari and Share extensions, exports it for App Store Connect, validates it and uploads one build.

## One-time setup

Done by an agent on 2026-11-11 (paid team NDMG62GXZA, individual, so it keeps the free team's ID):

- `DEVELOPMENT_TEAM = NDMG62GXZA` in `Config/Local.xcconfig` (gitignored; copy `Local.xcconfig.example` on a new Mac).
- This Mac registered with the team, development profiles created for the app and both extensions. `xcodebuild
  archive` cannot register a Mac, but a Debug build can. On another Mac, run this once:
  `xcodebuild -project Deepwell.xcodeproj -scheme Deepwell -destination 'platform=macOS' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`
- App IDs `com.tejaskale.deepwell`, `.SafariExtension` and `.ShareExtension` are registered, and the Apple
  Distribution and Mac Installer Distribution certificates are created. Xcode did both through
  `-allowProvisioningUpdates` during the first export.

You do these yourself, once:

1. App Store Connect > Apps > + New App: platform macOS, name Deepwell, bundle id `com.tejaskale.deepwell`, SKU
   `deepwell`, Full Access.
2. App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys: generate a key with the
   **App Manager** role. Download `AuthKey_<KEYID>.p8` (it downloads once only) and note the Key ID and Issuer ID.
3. Store the key outside the repo. Either keep the file (for example in `~/.appstoreconnect/private_keys/`) and set
   `ASC_KEY_PATH`, or put it in the login Keychain and delete the file:
   `security add-generic-password -s deepwell.asc-api-key -a <KEYID> -w "$(base64 -i AuthKey_<KEYID>.p8)"`.
   Then put `export ASC_KEY_ID=<KEYID> ASC_ISSUER_ID=<ISSUER>` (plus `ASC_KEY_PATH=...` if you kept the file) in
   your shell profile. Never commit the key: `build/` and `Config/Local.xcconfig` are gitignored, and the script
   copies the key into a private temp folder that it deletes on exit.
4. Run `scripts/release.sh` (below). When the build has processed, open it in TestFlight > macOS, add yourself to
   an internal testing group and enable the build for it. Install the TestFlight app from the Mac App Store and
   accept the invite.

## Releasing a build

```sh
scripts/release.sh                 # bump CURRENT_PROJECT_VERSION, archive, export, validate, upload
scripts/release.sh --export-only   # stop after a locally checked .pkg (no API key needed)
scripts/release.sh --keep-build    # reuse the current build number, e.g. after a failed run
```

Each run:

- bumps `CURRENT_PROJECT_VERSION` in `project.yml` (commit it afterwards);
- runs `xcodegen generate`;
- archives Release (`-allowProvisioningUpdates`) to `build/release/Deepwell.xcarchive`;
- exports with method `app-store-connect` to `build/release/export/Deepwell.pkg`;
- checks that each bundle (the app and both extensions) is signed by the team, has the app group and the sandbox,
  and embeds a provisioning profile;
- runs `altool --validate-app`, then `altool --upload-app`, and records the build number in `build/release/uploaded`.

Signing (archive and export) uses the Apple ID signed in to Xcode > Settings > Accounts, the team's Account Holder.
That account may use Apple's cloud-managed distribution certificates, so none are needed in your Keychain. The API
key is used only to validate and upload. An App Manager key cannot use cloud signing; passing it to `xcodebuild`
fails with "Cloud signing permission error".

Without `ASC_KEY_ID`/`ASC_ISSUER_ID` the script stops before changing anything and says what is missing. A failed
run is safe to re-run. It only skips a build number, and `--keep-build` refuses a number that was already uploaded.
Bump `MARKETING_VERSION` by hand for a user-visible version change.

Processing in App Store Connect takes a few minutes. TestFlight then offers the update on every Mac signed in with
your Apple ID.

**Builds expire 90 days after upload.** An expired build stops launching. Upload a fresh one before then (any
change, or just re-run the script). Expiry does not touch your library: it lives in iCloud Drive, not in the app.

## Data across the switch

- **Library (`iCloud Drive/Deepwell`):** plain files outside the app. No build or install touches them.
- **Capture inbox:** the app group stays `$(TeamIdentifierPrefix)dev.deepwell`, so the inbox is still
  `~/Library/Group Containers/NDMG62GXZA.dev.deepwell/Inbox`. Because the team ID is the same, the old local
  build, the TestFlight build and `install.sh` builds all share it. On first launch, the TestFlight build drains
  any pending captures into the library, as every launch does. If no library folder is chosen yet, they stay queued.
- **Settings, library bookmark, Keychain keys:** keyed by the bundle id `com.tejaskale.deepwell`, which is
  unchanged. Verified 2026-11-11: the TestFlight build kept the settings, library bookmark and keys written by the
  development-signed build.
- Before the first TestFlight install: open the current Deepwell once so pending captures drain, then quit it and
  move the locally built `/Applications/Deepwell.app` to the Trash. TestFlight does not overwrite a differently signed
  copy. It installs next to it as `Deepwell 2.app`, and the scripts treat `/Applications/Deepwell.app` as the
  installed one. If that already happened: quit both, trash the old copy, rename `Deepwell 2.app` to `Deepwell.app`
  (TestFlight finds it by bundle id), then run `scripts/unregister-stale-builds.sh`.

## Fallback: local build without TestFlight

`scripts/install.sh` still builds Release signed for development and copies it over `/Applications/Deepwell.app`.
Use it to try a change without uploading. It replaces a TestFlight install; reinstall from TestFlight to go back.
`--zip` writes `build/local/Deepwell-<version>.zip`, which runs only on Macs registered to the team.

## One Safari extension

Every build registers its own copy of the Safari and Share extensions. `scripts/unregister-stale-builds.sh` (run by
both scripts) unregisters every Deepwell.app except `/Applications/Deepwell.app`. Run it yourself if Safari lists
two Deepwell extensions, for example after building in Xcode.

General > "Bring Deepwell to the front" decides what a save from Safari or the Share menu does: the extensions
always wake the app without activating it (`SharedConfig.wakeApp`), and the app activates itself if the setting is on.
