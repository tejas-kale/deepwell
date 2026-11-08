import SwiftUI

@main
struct DeepwellApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 480, minHeight: 320)
                .onOpenURL { _ in model.drainInbox() }   // deepwell://inbox wake-up from the extension
        }
    }
}
