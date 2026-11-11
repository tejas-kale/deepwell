import Foundation
import SafariServices
import DeepwellCapture

/// Receives `{type:"capture", payload:{...}}` from background.js and queues it for the app. The same file is the
/// native handler of the Mac extension and the iOS one (ticket 18); each finds its own app group's inbox.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        let reply: [String: Any]
        do {
            guard message?["type"] as? String == "capture", let raw = message?["payload"] else {
                throw NSError(domain: "Deepwell", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown message"])
            }
            let data = try JSONSerialization.data(withJSONObject: raw)
            let payload = try JSONDecoder().decode(CapturePayload.self, from: data)
            try CaptureInbox(directory: SharedConfig.inboxDirectory).enqueue(payload)
            #if os(macOS)
            // Wake the app so the capture is written right away (app also drains on launch/timer).
            SharedConfig.wakeApp()
            #endif
            // iOS: an extension can't open its app; the app ingests the inbox on its next launch or foreground.
            reply = ["ok": true]
        } catch {
            reply = ["ok": false, "error": "Deepwell: \(error.localizedDescription)"]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
