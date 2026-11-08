import SwiftUI

@main
struct DeepwellApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // A single window: `WindowGroup` opens a new window (and a second library index) for every deepwell:// wake-up.
        Window("Deepwell", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1000, minHeight: 560)
                .onOpenURL { url in   // deepwell://inbox wake-up from the extensions, or a PDF/EPUB opened via the Dock icon
                    if url.isFileURL { model.importMagazines([url]) } else { model.drainInbox() }
                }
        }
        .commands {
            CommandMenu("Library") {
                Button("Build New Focus") { NotificationCenter.default.post(name: .deepwellBuildFocus, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Weekly Menu") { NotificationCenter.default.post(name: .deepwellOpenMenu, object: nil) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Manage Tags…") { NotificationCenter.default.post(name: .deepwellManageTags, object: nil) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Rebuild Index") { NotificationCenter.default.post(name: .deepwellRebuildIndex, object: nil) }
            }
        }
        Settings { SettingsView(tagging: model.tagging) }
    }
}
