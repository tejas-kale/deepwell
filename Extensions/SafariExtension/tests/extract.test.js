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

test("substack linked image with commas in srcset URLs keeps the full image URL", () => {
  const cdn = "https://substackcdn.com/image/fetch/$s_!TXCo!,w_1456,c_limit,f_webp,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fabc_1400x400.png";
  const full = "https://substackcdn.com/image/fetch/$s_!TXCo!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fabc_1400x400.png";
  const para = "<p>" + "Retrieval systems are simpler than people think and most teams over-engineer them badly. ".repeat(12) + "</p>";
  const html = `<html><head><title>RAG</title></head><body><article><h1>RAG</h1>${para}
    <figure><a class="image-link" href="${full}"><picture>
      <source type="image/webp" srcset="${cdn.replace("w_1456", "w_424")} 424w, ${cdn} 1456w">
      <img src="${cdn.replace("w_1456", "w_424")}" srcset="${cdn.replace("w_1456", "w_424")} 424w, ${cdn} 1456w" alt="Flow diagram">
    </picture></a></figure>${para}${para}</article></body></html>`;
  const dom = new JSDOM(html, { url: "https://www.lighthousenewsletter.com/p/rag" });
  const r = extract(dom.window.document, "https://www.lighthousenewsletter.com/p/rag", { Readability, TurndownService, gfm });
  assertClean(r);
  assert.ok(r.markdown.includes(`![Flow diagram](${full})`), r.markdown.slice(0, 2000));
  assert.ok(!/^\[$/m.test(r.markdown), "no stray [ line");
  assert.ok(!r.markdown.includes("lighthousenewsletter.com/p/fl_"), "no URL broken at a comma");
});

test("headings with chrome-like classes (Substack's header-anchor-post) survive", () => {
  const para = "<p>" + "Most teams over-engineer retrieval when full-text search would do the job well enough. ".repeat(12) + "</p>";
  const html = `<html><head><title>RAG</title></head><body><article><h1>RAG</h1>${para}
    <h3 class="header-anchor-post">Recipe 1: The MVP</h3>${para}
    <h4 class="header-anchor-post">When to use</h4>${para}</article></body></html>`;
  const dom = new JSDOM(html, { url: "https://example.substack.com/p/rag" });
  const r = extract(dom.window.document, "https://example.substack.com/p/rag", { Readability, TurndownService, gfm });
  assertClean(r);
  assert.match(r.markdown, /^### Recipe 1: The MVP$/m);
  assert.match(r.markdown, /^#### When to use$/m);
});
