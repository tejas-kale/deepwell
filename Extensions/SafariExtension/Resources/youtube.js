// Deepwell YouTube capture: pure parsing/formatting helpers plus one orchestrator.
// Runs unchanged in Safari (content script, global DeepwellYouTube) and in node (tests, via require).
// Only `capture()` touches the network (through the injected `io.fetchText`); everything else is pure.
(function (root, api) {
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DeepwellYouTube = api;
})(typeof self !== "undefined" ? self : this, (function () {
  const ID_RE = /^[A-Za-z0-9_-]{11}$/;

  /** Returns the video id for a youtube.com/watch URL (or youtu.be/<id>), else null. */
  function videoIdFromUrl(url) {
    let u;
    try { u = new URL(url); } catch (_) { return null; }
    const host = u.hostname.replace(/^(www\.|m\.|music\.)/, "");
    if (host === "youtube.com" && u.pathname === "/watch") {
      const v = u.searchParams.get("v");
      return v && ID_RE.test(v) ? v : null;
    }
    if (host === "youtu.be") {
      const v = u.pathname.slice(1);
      return ID_RE.test(v) ? v : null;
    }
    return null;
  }

  function isWatchUrl(url) { return videoIdFromUrl(url) !== null; }
  function canonicalUrl(id) { return "https://www.youtube.com/watch?v=" + id; }

  /** Extracts the `ytInitialPlayerResponse` JSON object from watch-page HTML (brace matching, string aware). */
  function extractPlayerResponse(html) {
    const marker = /ytInitialPlayerResponse\s*=\s*/.exec(html);
    if (!marker) return null;
    const start = marker.index + marker[0].length;
    if (html[start] !== "{") return null;
    let depth = 0, inStr = false, esc = false;
    for (let i = start; i < html.length; i++) {
      const c = html[i];
      if (inStr) {
        if (esc) esc = false;
        else if (c === "\\") esc = true;
        else if (c === '"') inStr = false;
      } else if (c === '"') inStr = true;
      else if (c === "{") depth++;
      else if (c === "}" && --depth === 0) {
        try { return JSON.parse(html.slice(start, i + 1)); } catch (_) { return null; }
      }
    }
    return null;
  }

  /** Minutes rounded up (a 61 s video is 2 min), at least 1; null if unknown. */
  function durationMinutes(lengthSeconds) {
    const s = Number(lengthSeconds);
    return Number.isFinite(s) && s > 0 ? Math.max(1, Math.ceil(s / 60)) : null;
  }

  /** Normalises player-response caption tracks to {url, lang, kind, name}; kind is "manual" or "asr". */
  function captionTracks(playerResponse) {
    const list = playerResponse && playerResponse.captions &&
      playerResponse.captions.playerCaptionsTracklistRenderer &&
      playerResponse.captions.playerCaptionsTracklistRenderer.captionTracks;
    if (!Array.isArray(list)) return [];
    return list.filter((t) => t && t.baseUrl).map((t) => ({
      url: t.baseUrl,
      lang: t.languageCode || "",
      kind: t.kind === "asr" ? "asr" : "manual",
      name: (t.name && (t.name.simpleText || (t.name.runs || []).map((r) => r.text).join(""))) || "",
    }));
  }

  /**
   * Picks the track to use: any manual track beats auto-generated. Within a kind, prefer the
   * caller's languages in order, then English, then whatever is first.
   */
  function pickTrack(tracks, preferredLangs) {
    if (!tracks || !tracks.length) return null;
    const langs = (preferredLangs || []).map((l) => String(l).toLowerCase().split("-")[0]);
    const base = (t) => t.lang.toLowerCase().split("-")[0];
    const rank = (t) => {
      const i = langs.indexOf(base(t));
      return i >= 0 ? i : langs.length + (base(t) === "en" ? 0 : 1);
    };
    const best = (list) => list.slice().sort((a, b) => rank(a) - rank(b))[0];
    const manual = tracks.filter((t) => t.kind === "manual");
    return best(manual.length ? manual : tracks);
  }

  function decodeEntities(s) {
    return s
      .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
      .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
      .replace(/&amp;/g, "&");
  }

  function cleanCueText(s) {
    return s.replace(/​/g, "").replace(/\s*\n\s*/g, " ").replace(/\s+/g, " ").trim();
  }

  /** Parses `fmt=json3` timedtext into [{start (seconds), text}]. */
  function parseJson3(text) {
    let data;
    try { data = JSON.parse(text); } catch (_) { return []; }
    const cues = [];
    for (const ev of (data && data.events) || []) {
      if (!ev.segs) continue; // window/style events carry no text
      const t = cleanCueText(ev.segs.map((s) => s.utf8 || "").join(""));
      if (t) cues.push({ start: (ev.tStartMs || 0) / 1000, text: t });
    }
    return cues;
  }

  /** Parses classic XML timedtext (`<transcript><text start="1.2" dur="3">..</text>`) into cues. */
  function parseXml(text) {
    const cues = [];
    const re = /<text\b[^>]*?\bstart="([\d.]+)"[^>]*>([\s\S]*?)<\/text>/g;
    let m;
    while ((m = re.exec(text))) {
      // Entities are double-encoded in this format (&amp;#39;), so decode twice.
      // Formatting tags (<i>, <font ...>) can appear both raw and entity-encoded, so strip after decoding too.
      const decoded = decodeEntities(decodeEntities(m[2].replace(/<[^>]+>/g, "")));
      const t = cleanCueText(decoded.replace(/<\/?(?:i|b|u|font)\b[^>]*>/gi, ""));
      if (t) cues.push({ start: parseFloat(m[1]), text: t });
    }
    return cues;
  }

  function parseTimedText(text) {
    const trimmed = (text || "").trim();
    return trimmed.startsWith("{") ? parseJson3(trimmed) : parseXml(trimmed);
  }

  function formatTimestamp(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    const two = (n) => String(n).padStart(2, "0");
    return h > 0 ? `${h}:${two(m)}:${two(sec)}` : `${m}:${two(sec)}`;
  }

  /**
   * Cues -> Markdown. One paragraph per ~`windowSeconds` of speech, each starting with a
   * timestamp link that jumps to that moment on YouTube:
   *   [1:05](https://www.youtube.com/watch?v=ID&t=65s) text text text
   * The Swift reader (DeepwellYouTube.TranscriptParser) parses exactly this shape.
   */
  function buildTranscriptMarkdown(cues, videoId, windowSeconds) {
    const win = windowSeconds || 30;
    const paras = [];
    let cur = null;
    for (const c of cues) {
      if (!cur || c.start - cur.start >= win) {
        cur = { start: c.start, parts: [] };
        paras.push(cur);
      }
      cur.parts.push(c.text);
    }
    return paras
      .map((p) => `[${formatTimestamp(p.start)}](${canonicalUrl(videoId)}&t=${Math.floor(p.start)}s) ${p.parts.join(" ")}`)
      .join("\n\n");
  }

  const NEEDS_TRANSCRIPT_BODY =
    "_No published captions were available for this video. Deepwell will transcribe it on this Mac once on-device transcription is available._";

  /**
   * Builds the payload sent to native code. `captionCues` is null/empty when the video has no
   * usable captions; then `needsTranscript` is true (frontmatter `needs_transcript: true`, ticket 06).
   */
  function buildPayload({ videoId, playerResponse, captionCues, track, now }) {
    const d = (playerResponse && playerResponse.videoDetails) || {};
    const has = Array.isArray(captionCues) && captionCues.length > 0;
    return {
      type: "youtube",
      url: canonicalUrl(videoId),
      title: d.title || "YouTube video " + videoId,
      author: d.author || "",
      siteName: "YouTube",
      excerpt: "",
      markdown: has ? buildTranscriptMarkdown(captionCues, videoId) : NEEDS_TRANSCRIPT_BODY,
      wordCount: has ? captionCues.map((c) => c.text).join(" ").split(/\s+/).filter(Boolean).length : 0,
      durationMinutes: durationMinutes(d.lengthSeconds),
      videoId,
      needsTranscript: !has,
      captionKind: has && track ? track.kind : null,
      captionLang: has && track ? track.lang : null,
      capturedAt: (now || new Date()).toISOString(),
    };
  }

  /**
   * Full capture. `io.fetchText(url)` must return the response text (rejecting on HTTP errors).
   * Never throws for "no captions"; throws only if the watch page itself cannot be read.
   */
  async function capture(url, io) {
    const videoId = videoIdFromUrl(url);
    if (!videoId) throw new Error("Not a YouTube watch page");
    const html = await io.fetchText(canonicalUrl(videoId));
    const playerResponse = extractPlayerResponse(html);
    if (!playerResponse) throw new Error("Could not read the YouTube player data");
    const track = pickTrack(captionTracks(playerResponse), io.preferredLangs);
    let cues = [];
    if (track) {
      try {
        const sep = track.url.includes("?") ? "&" : "?";
        cues = parseTimedText(await io.fetchText(track.url + sep + "fmt=json3"));
      } catch (_) { cues = []; }
    }
    return buildPayload({ videoId, playerResponse, captionCues: cues, track, now: io.now });
  }

  return {
    videoIdFromUrl, isWatchUrl, canonicalUrl, extractPlayerResponse, durationMinutes, captionTracks,
    pickTrack, parseJson3, parseXml, parseTimedText, formatTimestamp, buildTranscriptMarkdown,
    buildPayload, capture, NEEDS_TRANSCRIPT_BODY,
  };
})());
