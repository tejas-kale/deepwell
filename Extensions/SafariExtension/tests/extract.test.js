const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { JSDOM } = require("jsdom");
const Readability = require("@mozilla/readability").Readability;
const TurndownService = require("turndown");
const gfm = require("turndown-plugin-gfm").gfm;
const extract = require("../Resources/extract.js");

function run(file, url) {
  const html = fs.readFileSync(path.join(__dirname, "fixtures", file), "utf8");
  const dom = new JSDOM(html, { url });
  return extract(dom.window.document, url, { Readability, TurndownService, gfm });
}

function assertClean(r) {
  assert.ok(r, "extraction returned a result");
  assert.ok(!/<script|<style|<nav|<div/i.test(r.markdown), "no raw HTML left");
  assert.ok(!/\n{3,}/.test(r.markdown), "no triple blank lines");
}

test("paulgraham essay", () => {
  const r = run("paulgraham-greatwork.html", "https://paulgraham.com/greatwork.html");
  assertClean(r);
  assert.match(r.title, /How to Do Great Work/);
  assert.match(r.markdown, /The first step is to decide what to work on/);
  assert.ok(r.wordCount > 10000, `word count ${r.wordCount}`);
});

test("wikipedia article", () => {
  const r = run("wikipedia-sourdough.html", "https://en.wikipedia.org/wiki/Sourdough");
  assertClean(r);
  assert.match(r.title, /Sourdough/);
  assert.match(r.markdown, /lactic acid bacteria/i);
  assert.ok(r.wordCount > 2000, `word count ${r.wordCount}`);
  assert.ok(!/Jump to content/.test(r.markdown), "site chrome removed");
});

test("martin fowler bliki", () => {
  const r = run("martinfowler-bliki.html", "https://martinfowler.com/bliki/CircuitBreaker.html");
  assertClean(r);
  assert.match(r.title, /Circuit Breaker/);
  assert.match(r.markdown, /circuit breaker/i);
  assert.ok(r.wordCount > 500, `word count ${r.wordCount}`);
  assert.ok(/^#|^\w/.test(r.markdown));
});

test("rust release blog", () => {
  const r = run("rust-blog.html", "https://blog.rust-lang.org/2024/05/02/Rust-1.78.0/");
  assertClean(r);
  assert.match(r.title, /Rust 1\.78\.0/);
  assert.match(r.markdown, /rustup/);
  assert.ok(r.wordCount > 500, `word count ${r.wordCount}`);
});

test("non-article page returns null or minimal", () => {
  const dom = new JSDOM("<html><body><p>hi</p></body></html>", { url: "https://x.test/" });
  const r = extract(dom.window.document, "https://x.test/", { Readability, TurndownService, gfm });
  assert.ok(r === null || r.wordCount < 50);
});
