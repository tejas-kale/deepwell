import SwiftUI
import AVFoundation

/// The iPhone/iPad companion (ticket 15): this week's Current Focus from the Mac's pick, and the shared reader.
/// It reads `.deepwell/menu.json` and never writes it; item status and progress go through `ItemFileUpdater`.
@main
struct DeepwellMobileApp: App {
    @State private var model: MobileAppModel

    init() {
        let model = MobileAppModel()
        _model = State(initialValue: model)
        // BGTaskScheduler wants every handler registered before launch finishes (ticket 16, phone tagging).
        model.tagger.registerBackgroundTask()
        // The notification delegate must be in place before launch finishes, so a tap on a reading nudge that
        // launched the app is still routed (docs/menu.md, Nudges).
        _ = UserNotificationNudgeScheduler.shared
        // Podcast audio plays with the ring/silent switch on silent, like any audio app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView().environment(model)
        }
    }
}
