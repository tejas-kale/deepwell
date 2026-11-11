import SwiftUI
import AVFoundation

/// The iPhone/iPad companion (ticket 15): this week's Current Focus from the Mac's pick, and the shared reader.
/// It reads `.deepwell/menu.json` and never writes it; item status and progress go through `ItemFileUpdater`.
@main
struct DeepwellMobileApp: App {
    @State private var model = MobileAppModel()

    init() {
        // Podcast audio plays with the ring/silent switch on silent, like any audio app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView().environment(model)
        }
    }
}
