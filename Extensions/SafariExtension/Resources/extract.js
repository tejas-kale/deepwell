// Deepwell article extraction: DOM -> { title, author, markdown, wordCount, ... }.
// Runs unchanged in Safari (content script, globals) and in node (tests, via require).
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory;
  } else {
    root.DeepwellExtract = { extract: factory };
  }
})(typeof self !== "undefined" ? self : this, function extract(doc, url, libs) {
  const { Readability, TurndownService, gfm } = libs;

  // Readability mutates the document it is given, so always work on a clone.
  const clone = doc.cloneNode(true);
  // Readability drops elements whose class or id looks like page chrome ("header", "social", ...). Substack marks
  // every section heading class="header-anchor-post", so all headings vanished. Headings are never chrome
  // inside an article; clear those attributes so they survive.
  clone.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => {
    h.removeAttribute("class");
    h.removeAttribute("id");
  });
  const article = new Readability(clone, { keepClasses: false }).parse();
  if (!article || !article.content) return null;

  const td = new TurndownService({
    headingStyle: "atx",
    codeBlockStyle: "fenced",
    bulletListMarker: "-",
    emDelimiter: "*",
    linkStyle: "inlined",
  });
  if (gfm) td.use(gfm);
  // GFM tables need a heading row; infoboxes and layout tables don't have one and
  // would otherwise be left as raw HTML. Flatten those to a plain list of rows.
  td.addRule("headinglessTable", {
    filter: (node) => {
      if (node.nodeName !== "TABLE" || !node.rows || !node.rows[0]) return false;
      const first = node.rows[0];
      const isHeading =
        first.parentNode.nodeName === "THEAD" ||
        Array.from(first.cells).every((c) => c.nodeName === "TH");
      return !isHeading;
    },
    replacement: (_content, node) => {
      const rows = Array.from(node.rows)
        .map((r) =>
          Array.from(r.cells)
            .map((c) => c.textContent.replace(/\s+/g, " ").trim())
            .filter(Boolean)
            .join(": ")
        )
        .filter(Boolean);
      return "\n\n" + rows.map((r) => "- " + r).join("\n") + "\n\n";
    },
  });
  // srcset is "url 424w, url 848w". URLs may themselves contain commas (Substack's image CDN does:
  // ".../fetch/$s_!x!,w_424,c_limit,f_webp/..."), so split on whitespace, not commas: a token that is a width or
  // density descriptor belongs to the URL before it.
  const parseSrcset = (srcset) => {
    const out = [];
    for (const tok of srcset.trim().split(/\s+/)) {
      const d = tok.match(/^(\d+(?:\.\d+)?)([wx]),?$/);
      if (d && out.length) {
        out[out.length - 1].width = d[2] === "w" ? parseFloat(d[1]) : parseFloat(d[1]) * 1000;
      } else if (tok && tok !== ",") {
        out.push({ url: tok.replace(/,$/, ""), width: 0 });
      }
    }
    return out;
  };
  const looksLikeImage = (u) =>
    /\/image\/fetch\/|substackcdn\.com\/image/i.test(u) || /\.(jpe?g|png|gif|webp|avif|heic|svg)(\?|$)/i.test(u);

  // An image wrapped in a link to its full-size file (Substack does this for every image) would come out as
  // "[\n\n![](src)\n\n](href)", which renders as a stray "[" and a raw URL. Emit just the image instead.
  td.addRule("linkedImage", {
    filter: (node) =>
      node.nodeName === "A" &&
      node.querySelector("img") &&
      node.textContent.trim() === "",
    replacement: (content, node) => {
      const href = node.getAttribute("href") || "";
      const m = content.match(/!\[([^\]]*)\]\(([^)\s]+)\)/);
      if (!m) return content;
      let abs = href;
      try { abs = new URL(href, url).href; } catch (e) {}
      return "\n\n![" + m[1] + "](" + (looksLikeImage(abs) ? abs : m[2]) + ")\n\n";
    },
  });

  // Lazy-loaded images (data-src, srcset-only, <picture>) have no usable src after Readability; recover one so the
  // reader can show the picture. Tiny/tracking placeholders (data: URIs, 1px gifs) are dropped.
  td.addRule("realImage", {
    filter: "img",
    replacement: (_c, node) => {
      const pick = () => {
        const cands = [node.getAttribute("src"), node.getAttribute("data-src"), node.getAttribute("data-original")];
        const srcset = node.getAttribute("srcset") || node.getAttribute("data-srcset");
        if (srcset) {
          const parts = parseSrcset(srcset);
          parts.sort((a, b) => b.width - a.width);   // widest first
          if (parts[0]) cands.unshift(parts[0].url);
        }
        return cands.find((c) => c && !c.startsWith("data:"));
      };
      const src = pick();
      if (!src) return "";
      let abs = src;
      try { abs = new URL(src, url).href; } catch (e) {}
      const alt = (node.getAttribute("alt") || "").replace(/[\[\]\n]/g, " ").trim();
      return "\n\n![" + alt + "](" + abs + ")\n\n";
    },
  });
  td.remove(["script", "style", "noscript", "iframe", "form", "button"]);

  let markdown = td.turndown(article.content);
  markdown = markdown.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();

  const meta = (sel) => {
    const el = doc.querySelector(sel);
    return el ? (el.getAttribute("content") || "").trim() : "";
  };
  const author =
    (article.byline || "").trim() ||
    meta('meta[name="author"]') ||
    meta('meta[property="article:author"]') ||
    "";
  const title = (article.title || doc.title || url).trim();
  const wordCount = markdown
    .replace(/[#>*`|_\-\[\]\(\)!]/g, " ")
    .split(/\s+/)
    .filter(Boolean).length;

  return {
    url,
    title,
    author,
    siteName: article.siteName || "",
    excerpt: article.excerpt || "",
    markdown,
    wordCount,
    capturedAt: new Date().toISOString(),
  };
});
