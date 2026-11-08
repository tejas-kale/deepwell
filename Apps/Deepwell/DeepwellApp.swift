import SwiftUI

@main
struct DeepwellApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 500)
                .onOpenURL { url in   // deepwell://inbox wake-up from the extensions, or a PDF/EPUB opened via the Dock icon
                    if url.isFileURL { model.importMagazines([url]) } else { model.drainInbox() }
                }
        }
        Settings { SettingsView(tagging: model.tagging) }
    }
}
