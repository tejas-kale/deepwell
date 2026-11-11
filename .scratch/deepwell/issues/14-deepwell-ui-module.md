# 14: Shared `DeepwellUI` module

**What to build:** A `DeepwellUI` library target in DeepwellCore, holding the SwiftUI views that work on both macOS and iOS. The Mac app imports it instead of its local copies. This is a pure refactor with no behaviour change on the Mac.

**Blocked by:** none (can run in parallel with 13)

**Status:** ready-for-agent

- [ ] Move to `DeepwellUI`: `MarkdownBody` (including the narration highlight input), the platform-neutral core of `ReaderView`, `Theme` (Ayu), `TagsView`, the YouTube transcript view, `TranscriptionStatusView` (now in DeepwellTranscription; decide whether it moves)
- [ ] AppKit uses (`NSColor`, `NSImage`, `NSWorkspace`, pasteboard, `PaneFocus` probes) replaced by SwiftUI equivalents, or kept behind small `#if os(macOS)` seams inside the module; the Mac-only `PaneFocus`, menus, Kindle and Settings stay in `Apps/Deepwell`
- [ ] `DeepwellUI` builds for both `macOS 14` and `iOS 26` (`swift build` for each, or `xcodebuild -destination 'generic/platform=iOS'`)
- [ ] The Mac app looks and behaves the same (screenshot comparison of reader, library and tags before and after)
