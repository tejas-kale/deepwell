import AppKit
import SafariServices
import DeepwellCapture

/// Receives `{type:"capture", payload:{...}}` from background.js and queues it for the app.
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
            // Wake the app so the capture is written right away (app also drains on launch/timer).
            NSWorkspace.shared.open(SharedConfig.wakeURL)
            reply = ["ok": true]
        } catch {
            reply = ["ok": false, "error": "Deepwell: \(error.localizedDescription)"]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
