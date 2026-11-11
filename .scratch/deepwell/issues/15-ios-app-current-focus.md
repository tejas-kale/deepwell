# 15: iOS app: Current Focus and reading (first shippable slice)

**What to build:** `Apps/DeepwellMobile`, an iPhone and iPad app (iOS 26) that opens the same iCloud container library. It shows this week's Current Focus queue from `.deepwell/menu.json`, opens items in the shared reader, and records status and progress back to the files. It ships through TestFlight.

**Blocked by:** 12, 13, 14

**Status:** done with unverified items (2026-11-11): built and uploaded to TestFlight as iOS 0.1.0 (5); the first device check passed (user, 2026-11-11); the other four are not verified yet (docs/ios.md → Not verified)

## Scope

- New `DeepwellMobile` target in `project.yml` (iOS 26, iPhone + iPad, the same iCloud container and App Group). DeepwellCore's `platforms` is raised to `.iOS(.v26)`. `scripts/release.sh` archives and uploads it as well.
- **iPhone:** a tab or stack with Current Focus (the ordered queue, each item's length and reason, time-weighted progress from `QueueProgress`) opening the reader. **iPad:** NavigationSplitView with sidebar → queue → reader.
- The phone **reads** `menu.json` and never writes it. With no pick yet, it shows "Build a menu on your Mac".
- The reader comes from `DeepwellUI`: Markdown articles, magazine articles (article text), YouTube (link out/embed) and podcasts (audio player plus transcript).
- Status (unread/reading/done) and scroll progress are written through the coordinated `ItemFileUpdater` with the same debounce as the Mac. Conflicts go through ticket 13's merge.
- The per-device SQLite index lives in the app's Application Support, built from the container on first launch and kept current from `NSMetadataQuery`.
- iCloud not signed in: a clear empty state, no local fallback on iOS.

## Acceptance

- [x] Fresh TestFlight install on iPhone shows the Mac's picked bundle in order with matching progress (user, build 5, 2026-11-11)
- [ ] Marking an item done on the phone updates the Mac's queue progress within a sync cycle, and vice versa
- [ ] Reading on both devices, then syncing, leaves no conflict files and keeps the furthest progress (manual two-device test, recorded)
- [ ] A new pick on the Mac appears on the phone without relaunching
- [ ] iPad shows three columns; rotation and split view work
- [x] `docs/ios.md`: architecture, what is shared, and verified vs not

Note: the iOS app icon is `Design/AppIcon/fullbleed-1024.png` as a single 1024 universal iOS entry in the mobile
target's asset catalog (no mask baked in). See `Design/AppIcon/README.md`.
