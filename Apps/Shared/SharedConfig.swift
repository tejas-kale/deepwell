import Foundation

/// Glue shared by the app and the Safari extension handler: where the capture inbox lives.
///
/// The extension (sandboxed appex) cannot use the app's security-scoped bookmark, so it drops
/// captures into a folder both can reach (the app-group container) and the app, which holds the
/// library bookmark, writes the Markdown files. See "Hand-off" in docs/safari-extension.md.
enum SharedConfig {
    /// Injected into both Info.plists from `$(TeamIdentifierPrefix)dev.deepwell` (project.yml).
    static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "DeepwellAppGroup") as? String) ?? "dev.deepwell"
    }

    static var inboxDirectory: URL {
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group.appendingPathComponent("Inbox", isDirectory: true)
        }
        // Unsigned/CI builds have no group container; fall back so nothing crashes (but app and
        // extension will not see the same folder).
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deepwell/Inbox", isDirectory: true)
    }

    static let wakeURL = URL(string: "deepwell://inbox")!
}
