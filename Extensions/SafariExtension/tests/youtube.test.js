const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const yt = require("../Resources/youtube.js");

const fx = (f) => fs.readFileSync(path.join(__dirname, "fixtures", "youtube", f), "utf8");
const NOW = new Date("2027-01-15T08:00:00Z");

test("videoIdFromUrl accepts watch pages only", () => {
  assert.strictEqual(yt.videoIdFromUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s"), "dQw4w9WgXcQ");
  assert.strictEqual(yt.videoIdFromUrl("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ");
  assert.strictEqual(yt.videoIdFromUrl("https://youtu.be/dQw4w9WgXcQ?si=x"), "dQw4w9WgXcQ");
  assert.strictEqual(yt.videoIdFromUrl("https://www.youtube.com/"), null);
  assert.strictEqual(yt.videoIdFromUrl("https://www.youtube.com/results?search_query=x"), null);
  assert.strictEqual(yt.videoIdFromUrl("https://www.youtube.com/shorts/dQw4w9WgXcQ"), null);
  assert.strictEqual(yt.videoIdFromUrl("https://www.youtube.com/watch?v=short"), null);
  assert.strictEqual(yt.videoIdFromUrl("https://evil.example/watch?v=dQw4w9WgXcQ"), null);
  assert.strictEqual(yt.videoIdFromUrl("not a url"), null);
});

test("extractPlayerResponse survives braces and quotes inside strings", () => {
  const pr = yt.extractPlayerResponse(fx("watch-with-captions.html"));
  assert.ok(pr);
  assert.strictEqual(pr.videoDetails.title, 'How Compilers Work: a {brace} "quoted" tour');
  assert.match(pr.videoDetails.shortDescription, /\} and \{/);
  assert.strictEqual(yt.extractPlayerResponse("<html>nothing</html>"), null);
});

test("duration rounds up to whole minutes", () => {
  assert.strictEqual(yt.durationMinutes("1805"), 31);
  assert.strictEqual(yt.durationMinutes("60"), 1);
  assert.strictEqual(yt.durationMinutes("61"), 2);
  assert.strictEqual(yt.durationMinutes("5"), 1);
  assert.strictEqual(yt.durationMinutes(undefined), null);
  assert.strictEqual(yt.durationMinutes("0"), null);
});

test("pickTrack prefers manual over auto-generated, even in a less preferred language", () => {
  const tracks = yt.captionTracks(yt.extractPlayerResponse(fx("watch-with-captions.html")));
  assert.deepStrictEqual(tracks.map((t) => t.kind + ":" + t.lang), ["asr:en", "manual:de", "manual:en"]);
  assert.strictEqual(tracks[2].name, "English");
  assert.strictEqual(yt.pickTrack(tracks, ["en-US"]).url.includes("lang=en&kind"), false);
  assert.strictEqual(yt.pickTrack(tracks, ["en-US"]).kind, "manual");
  assert.strictEqual(yt.pickTrack(tracks, ["en-US"]).lang, "en");
  assert.strictEqual(yt.pickTrack(tracks, ["de"]).lang, "de");
  assert.strictEqual(yt.pickTrack(tracks, ["fr"]).lang, "en", "falls back to English");
});

test("pickTrack falls back to auto-generated, and to null with no tracks", () => {
  const tracks = yt.captionTracks(yt.extractPlayerResponse(fx("watch-asr-only.html")));
  assert.strictEqual(yt.pickTrack(tracks, ["en"]).kind, "asr");
  assert.strictEqual(yt.pickTrack([], ["en"]), null);
  assert.deepStrictEqual(yt.captionTracks(yt.extractPlayerResponse(fx("watch-no-captions.html"))), []);
});

test("json3 parsing drops empty events and joins segments", () => {
  const cues = yt.parseTimedText(fx("timedtext-en.json3"));
  assert.deepStrictEqual(cues.map((c) => c.text), [
    "Welcome to the show.", "Today we look at compilers", "First, the lexer. It's simple.",
    "Then the parser.", "Thanks for watching.",
  ]);
  assert.strictEqual(cues[1].start, 4.1);
});

test("xml parsing decodes double-encoded entities and strips tags", () => {
  const cues = yt.parseTimedText(fx("timedtext-en.xml"));
  assert.deepStrictEqual(cues.map((c) => c.text), [
    "Welcome to the show.", "It's about compilers & interpreters", "Second paragraph",
  ]);
});

test("garbage timedtext yields no cues", () => {
  assert.deepStrictEqual(yt.parseTimedText(""), []);
  assert.deepStrictEqual(yt.parseTimedText("{not json"), []);
});

test("transcript markdown groups cues into timestamped paragraphs", () => {
  const md = yt.buildTranscriptMarkdown(yt.parseTimedText(fx("timedtext-en.json3")), "dQw4w9WgXcQ");
  const paras = md.split("\n\n");
  assert.strictEqual(paras.length, 3);
  assert.strictEqual(paras[0], "[0:00](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=0s) Welcome to the show. Today we look at compilers");
  assert.match(paras[1], /^\[0:31\]\(https:\/\/www\.youtube\.com\/watch\?v=dQw4w9WgXcQ&t=31s\) First, the lexer\. It's simple\. Then the parser\.$/);
  assert.match(paras[2], /^\[1:02:05\]\(.*&t=3725s\) Thanks for watching\.$/);
});

function io(pages) {
  const calls = [];
  return {
    calls, now: NOW, preferredLangs: ["en-US"],
    fetchText: async (url) => {
      calls.push(url);
      const hit = Object.keys(pages).find((k) => url.startsWith(k));
      if (!hit) throw new Error("HTTP 404");
      return pages[hit];
    },
  };
}

test("capture: video with manual captions", async () => {
  const i = io({
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ": fx("watch-with-captions.html"),
    "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en": fx("timedtext-en.json3"),
  });
  const p = await yt.capture("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1", i);
  assert.strictEqual(p.type, "youtube");
  assert.strictEqual(p.url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  assert.strictEqual(p.title, 'How Compilers Work: a {brace} "quoted" tour');
  assert.strictEqual(p.author, "Code Channel");
  assert.strictEqual(p.durationMinutes, 31);
  assert.strictEqual(p.needsTranscript, false);
  assert.strictEqual(p.captionKind, "manual");
  assert.strictEqual(p.capturedAt, "2027-01-15T08:00:00.000Z");
  assert.match(p.markdown, /^\[0:00\]/);
  assert.ok(p.wordCount > 15);
  assert.ok(i.calls[1].endsWith("&fmt=json3"));
  assert.ok(!i.calls[1].includes("kind=asr"), "manual track fetched, not the auto one");
});

test("capture: auto captions used when no manual track exists", async () => {
  const i = io({
    "https://www.youtube.com/watch?v=abcdefghijk": fx("watch-asr-only.html"),
    "https://www.youtube.com/api/timedtext": fx("timedtext-en.xml"),
  });
  const p = await yt.capture("https://www.youtube.com/watch?v=abcdefghijk", i);
  assert.strictEqual(p.captionKind, "asr");
  assert.strictEqual(p.needsTranscript, false);
  assert.strictEqual(p.durationMinutes, 1);
});

test("capture: no captions sets the needs-transcript marker", async () => {
  const p = await yt.capture("https://www.youtube.com/watch?v=zzzzzzzzzzz", io({
    "https://www.youtube.com/watch?v=zzzzzzzzzzz": fx("watch-no-captions.html"),
  }));
  assert.strictEqual(p.needsTranscript, true);
  assert.strictEqual(p.captionKind, null);
  assert.strictEqual(p.durationMinutes, 61);
  assert.strictEqual(p.wordCount, 0);
  assert.strictEqual(p.markdown, yt.NEEDS_TRANSCRIPT_BODY);
});

test("capture: caption download failure or empty track degrades to needs-transcript", async () => {
  const page = fx("watch-asr-only.html");
  const failing = await yt.capture("https://www.youtube.com/watch?v=abcdefghijk", io({ "https://www.youtube.com/watch?v=abcdefghijk": page }));
  assert.strictEqual(failing.needsTranscript, true);
  const empty = await yt.capture("https://www.youtube.com/watch?v=abcdefghijk", io({
    "https://www.youtube.com/watch?v=abcdefghijk": page,
    "https://www.youtube.com/api/timedtext": "",
  }));
  assert.strictEqual(empty.needsTranscript, true);
});

test("capture: unreadable watch page and non-watch URL throw", async () => {
  await assert.rejects(yt.capture("https://www.youtube.com/watch?v=dQw4w9WgXcQ", io({
    "https://www.youtube.com/watch": "<html>consent wall</html>",
  })), /player data/);
  await assert.rejects(yt.capture("https://www.youtube.com/", io({})), /watch page/);
});
