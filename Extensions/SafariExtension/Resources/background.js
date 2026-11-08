// Deepwell background script. Toolbar button and the keyboard shortcut
// (_execute_action in manifest.json) both fire action.onClicked.
const api = typeof browser !== "undefined" ? browser : chrome;

api.action.onClicked.addListener(async (tab) => {
  if (!tab || tab.id == null) return;
  try {
    // The content script extracts from the live DOM (so logged-in pages work),
    // and replies with a payload. Everything after this is fire-and-forget UI.
    const payload = await api.tabs.sendMessage(tab.id, { type: "deepwell.extract" });
    if (!payload || payload.error) {
      await notify(tab.id, "error", (payload && payload.error) || "Nothing readable on this page");
      return;
    }
    await notify(tab.id, "saving", "Saving to Deepwell…");
    const reply = await api.runtime.sendNativeMessage("application.id", {
      type: "capture",
      payload,
    });
    if (reply && reply.ok) {
      await notify(tab.id, "ok", "Saved to Deepwell");
    } else {
      await notify(tab.id, "error", (reply && reply.error) || "Deepwell could not save this page");
    }
  } catch (e) {
    await notify(tab.id, "error", "Deepwell: " + (e && e.message ? e.message : e));
  }
});

async function notify(tabId, state, text) {
  try {
    await api.tabs.sendMessage(tabId, { type: "deepwell.toast", state, text });
  } catch (_) {
    /* tab may have navigated away; saving already happened */
  }
}
