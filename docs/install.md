# Installing Deepwell on your Mac

```sh
scripts/install.sh          # Release build, quit running Deepwell, replace /Applications/Deepwell.app, launch
scripts/install.sh --zip    # also writes build/release/Deepwell-<version>.zip
```

Signed with your personal team's Apple Development certificate (`DEVELOPMENT_TEAM` in `Config/Local.xcconfig`), so
it runs on Macs signed in with that Apple ID's certificate, not as a distributable app (that needs a paid account,
Developer ID signing and notarization). Settings, the library folder bookmark and Keychain keys are keyed by the
bundle id, so they carry over from the Debug build.

After installing, the script registers `/Applications/Deepwell.app` with Launch Services so it, not an old Debug
build in DerivedData, handles `deepwell://` and provides the Safari and Share extensions. If Safari lists two
Deepwell extensions, delete the old DerivedData builds (Xcode > Settings > Locations > DerivedData).
Bump `MARKETING_VERSION` in `project.yml` to tell builds apart.

General > "Bring Deepwell to the front" decides what a save from Safari or the Share menu does: the extensions
always wake the app without activating it (`SharedConfig.wakeApp`), and the app activates itself if the setting is on.
