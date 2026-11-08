// Deepwell content script: extracts the readable article and shows a toast.
(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;

  function extractNow() {
    try {
      const result = DeepwellExtract.extract(document, location.href, {
        Readability,
        TurndownService,
        gfm: typeof turndownPluginGfm !== "undefined" ? turndownPluginGfm.gfm : null,
      });
      return result || { error: "Nothing readable on this page" };
    } catch (e) {
      return { error: "Extraction failed: " + e.message };
    }
  }

  let toastEl = null;
  let hideTimer = null;
  function toast(state, text) {
    if (!toastEl) {
      toastEl = document.createElement("div");
      toastEl.setAttribute("data-deepwell-toast", "");
      toastEl.style.cssText =
        "all:initial;position:fixed;top:16px;right:16px;z-index:2147483647;" +
        "font:600 13px -apple-system,system-ui,sans-serif;padding:10px 14px;border-radius:10px;" +
        "color:#fff;box-shadow:0 4px 16px rgba(0,0,0,.3);transition:opacity .25s;pointer-events:none;";
      document.documentElement.appendChild(toastEl);
    }
    toastEl.textContent = text;
    toastEl.style.background = state === "error" ? "#b3261e" : state === "ok" ? "#1e7a3c" : "#1854a0";
    toastEl.style.opacity = "1";
    clearTimeout(hideTimer);
    if (state !== "saving") hideTimer = setTimeout(() => (toastEl.style.opacity = "0"), 2500);
  }

  api.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg && msg.type === "deepwell.extract") {
      sendResponse(extractNow());
    } else if (msg && msg.type === "deepwell.toast") {
      toast(msg.state, msg.text);
      sendResponse({});
    }
    return false;
  });
})();
