// Ticket 18: the iOS Share Extension's preprocessing file, built from these same Resources by
// scripts/build-share-preprocessing.sh, run inside a page the way Safari runs it (as a page script).
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { JSDOM } = require("jsdom");

const built = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "dw-pre-")), "DeepwellPreprocessing.js");
execFileSync(path.join(__dirname, "../../../scripts/build-share-preprocessing.sh"), [built]);
const source = fs.readFileSync(built, "utf8");

function runIn(html, url, { fetchImpl, module } = {}) {
  const dom = new JSDOM(html, { url, runScripts: "outside-only" });
  if (fetchImpl) dom.window.fetch = fetchImpl;
  if (module) dom.window.module = module;   // a page that defines its own `module` global
  dom.window.eval(source);
  return new Promise((resolve) => dom.window.ExtensionPreprocessingJS.run({ completionFunction: resolve }));
}

const fixture = (f) => fs.readFileSync(path.join(__dirname, "fixtures", f), "utf8");

test("an article page yields a capture payload", async () => {
  const r = await runIn(fixture("paulgraham-greatwork.html"), "https://paulgraham.com/greatwork.html");
  assert.ok(r.payload, JSON.stringify(r).slice(0, 200));
  const p = JSON.parse(r.payload);
  assert.match(p.title, /How to Do Great Work/);
  assert.strictEqual(p.url, "https://paulgraham.com/greatwork.html");
  assert.ok(p.wordCount > 10000);
});

test("a page global named module doesn't break it", async () => {
  const r = await runIn(fixture("rust-blog.html"), "https://blog.rust-lang.org/post", { module: { exports: {} } });
  assert.ok(r.payload);
});

test("an unreadable page returns an error with the URL and title", async () => {
  const r = await runIn("<html><head><title>Empty</title></head><body></body></html>", "https://example.com/x");
  assert.strictEqual(r.payload, undefined);
  assert.strictEqual(r.url, "https://example.com/x");
  assert.strictEqual(r.title, "Empty");
  assert.match(r.error, /Nothing readable/);
});

test("a YouTube watch page without captions is marked needsTranscript", async () => {
  const page = fixture("youtube/watch-no-captions.html");
  const fetchImpl = async () => ({ ok: true, status: 200, text: async () => page });
  const r = await runIn(page, "https://m.youtube.com/watch?v=dQw4w9WgXcQ", { fetchImpl });
  assert.ok(r.payload, JSON.stringify(r));
  const p = JSON.parse(r.payload);
  assert.strictEqual(p.type, "youtube");
  assert.strictEqual(p.needsTranscript, true);
});
