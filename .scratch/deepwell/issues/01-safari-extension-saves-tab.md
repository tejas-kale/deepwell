# 01: Safari extension saves the current tab as Markdown

**What to build:** A minimal Deepwell Mac app plus a Safari Web Extension. On first launch the app asks for a library folder (default `iCloud Drive/Deepwell`). In Safari, clicking the extension button or pressing its keyboard shortcut extracts the readable article from the current tab (Readability/Defuddle), converts it to Markdown and saves one `.md` file with YAML frontmatter into the library folder. This ticket also settles the risk named in spec.md: whether an extension built with a free Apple ID needs "Allow Unsigned Extensions" re-enabled after every Safari restart.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] First launch shows a folder picker defaulting to `iCloud Drive/Deepwell`; the choice persists across launches (security-scoped bookmark)
- [ ] Toolbar button and keyboard shortcut both save the current tab, including pages behind a Safari login
- [ ] Saved file has frontmatter `id, type: article, title, source_url, author, captured_at, word_count, tags: [], status: unread, progress: 0` and a clean Markdown body
- [ ] Saving gives visible confirmation in Safari and never blocks browsing
- [ ] Extraction unit tests cover at least 3 saved real-world HTML fixtures
- [ ] Unsigned-extension behaviour across Safari restarts is tested on a free-account build and the result recorded in spec.md (Platform → Risk), with a workaround if one is needed
