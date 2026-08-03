# Vendored typography libraries

The files in this directory are local, pinned copies used by the browser-side
line breaker. They are loaded without any runtime network access.

- `typeset/linked-list.js` and `typeset/linebreak.js` are unchanged source
  files from `bramstein/typeset` commit
  `48ebb5547de116db57e14454e19767e4ff9b2266` (BSD-2-Clause).
- `hypher/hypher.browser.js` is the upstream browser wrapper, core, and suffix
  concatenated in their documented build order from `bramstein/Hypher` commit
  `3ff0220d4befce36ac3016e7c8c378063fe223b8` (BSD-3-Clause).
- `hyphenation-patterns/en-us.js` is the unchanged browser distribution from
  `bramstein/hyphenation-patterns` commit
  `dc01d58a667eece8d082ec3c3a1e88ed332bf802`. The pattern repository's README
  is retained beside it and records the patterns' LGPL licensing and source
  attribution requirements.
