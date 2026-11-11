// Tail of DeepwellPreprocessing.js, the iOS Share Extension's NSExtensionJavaScriptPreprocessingFile (ticket 18).
// scripts/build-share-preprocessing.sh wraps the Safari extension's own files (readability, turndown, gfm,
// extract.js, youtube.js from Extensions/SafariExtension/Resources) and this shim in one function, so the share
// sheet extracts with exactly the code the Safari extension runs. It runs inside the page, with the user's logins.
// The result goes to ShareViewController as { payload: "<CapturePayload JSON>" } or { url, title, error }.

  function fail(message) {
    return { url: location.href, title: document.title || "", error: String(message) };
  }

  async function fetchText(url) {
    const res = await fetch(url, { credentials: "include" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res.text();
  }

  return {
    run: function (args) {
      const done = function (result) { args.completionFunction(result); };
      const href = location.href;
      if (DeepwellYouTube.isWatchUrl(href)) {
        DeepwellYouTube.capture(href, { fetchText, preferredLangs: [...(navigator.languages || []), "en"] })
          .then(function (p) {
            done(p && !p.error ? { payload: JSON.stringify(p) } : fail((p && p.error) || "No video data on this page"));
          })
          .catch(function (e) { done(fail("YouTube capture failed: " + (e && e.message ? e.message : e))); });
        return;
      }
      try {
        const result = DeepwellExtract.extract(document, href, {
          Readability,
          TurndownService,
          gfm: typeof turndownPluginGfm !== "undefined" ? turndownPluginGfm.gfm : null,
        });
        done(result ? { payload: JSON.stringify(result) } : fail("Nothing readable on this page"));
      } catch (e) {
        done(fail("Extraction failed: " + (e && e.message ? e.message : e)));
      }
    },
    finalize: function () {},
  };
