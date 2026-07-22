# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A custom Pandoc Markdown→HTML rendering pipeline for math/academic documents,
implemented as Pandoc **Lua reader + filter + writer** modules plus a live-reload
preview server. It is a Lua port of the document-processing parts of a former
Hakyll pipeline (`ChaoDoc.hs`), so some naming (`HAKYLL_PANDOCMD_ASSETS`,
"Hakyll-style" template substitution) references that lineage.

## Commands

Build one Markdown file with the full pipeline (order of `-f`/`-L`/`-t` matters):

```sh
pandoc main.md -f lua/reader.lua -L lua/filter.lua -t lua/writer.lua -o out.html
```

Preview a file with rebuild-on-save and browser live reload:

```sh
bin/pandocmd-preview path/to/main.md       # build once, ensure hub, watch, auto-reload
bin/pandocmd-preview --build-only file.md  # build once and print the preview URL
bin/pandocmd-preview --hash-only file.md   # print the stable preview hash
bin/pandocmd-preview --stop                # stop the persistent live-reload hub daemon
```

Install the `ppl` alias (symlink of `bin/pandocmd-preview`) and its fish completion:

```sh
make install        # = link-bin + link-fish-completion (into ~/.local/bin, ~/.config/fish/completions)
```

The preview relies on a local **nginx** (serves `assets/` on port 80) plus a
persistent live-reload hub daemon — see the Preview / live reload section for the
one-time nginx setup (`nginx/pandocmd.conf` + a web-root symlink).

Runtime dependencies (Homebrew): `pandoc`, `fish`, `entr`, `python`, `nginx`. There
is a focused Lua regression suite, run under Pandoc with `make test`. The `test/`
directory is gitignored and holds sample `.md` documents used to verify the full
pipeline manually by building/previewing them.

## Architecture

### Three-stage Pandoc pipeline

The pipeline is deliberately split across Pandoc's three extension points because
each does work the others cannot:

1. **`lua/reader.lua` (`Reader`)** — pre-parse, text-level work that must happen
   before Markdown is parsed into an AST:
   - parses YAML front matter itself (to read config before the body is parsed),
   - normalizes theorem fence titles written *after* the attribute block
     (`::: {.theorem #x} My title` → `title="My title"` attribute),
   - injects `<!-- pandocmd-source-line:N -->` HTML comment markers before block
     starts (see Source lines below),
   - prepends TeX macros (`assets/math-macros.tex` + `meta.math` entries) so every
     document shares them.
   It then calls `pandoc.read` with the fixed reader format
   `markdown+tex_math_double_backslash+tex_math_single_backslash+latex_macros+raw_tex`
   and stashes `pandocmd-source-file` / `pandocmd-assets-dir` into `doc.meta`.

2. **`lua/filter.lua` (`Pandoc`)** — the AST transform entrypoint. It runs the
   passes below **in a fixed order because they depend on each other**; do not
   reorder casually:
   - `equations.preprocess_blocks` → wraps display math, extracts `\tag`, assigns
     numbers, returns `eq id → number` links. Must run before source-lines (which
     attach line labels onto the equation spans it produces).
   - `source_lines.annotate_blocks` → consumes the source-line markers.
   - `theorems.preprocess_blocks` → numbers theorem-like divs, returns
     `id → "Theorem 3"` links. Must run before autoref.
   - The equation, theorem, and `references.section_numbers` maps are merged into a
     single `links` table, which `references.autoref_blocks` uses to turn `[@id]`
     citations that point at those ids into cross-reference `<a>` links.
   - `page_meta.apply` → generates the TOC, stylesheet `<link>` tags, and citeproc
     metadata into `doc.meta` (`toc`, `stylesheets`, csl/bibliography settings).
   - `theorems.render_blocks`, `sidenotes.render_blocks`, `unwrap_div_paragraphs`.
   - `pandoc.utils.citeproc` runs **last**, only if `bibliography` is set.

3. **`lua/writer.lua` (`Writer`)** — renders the body to `html5` once, then does
   **literal string substitution** into `assets/templates/default.html` (`$title$`,
   `$body$`, `$toc$`, `$stylesheets$`, `$abstract$`, `$live-reload$`, plus
   `$if(...)$…$endif$`). It does NOT use Pandoc's template engine, which would
   reindent multiline HTML fragments and diverge from the intended output.

`lua/util.lua` holds shared helpers. Note `util.walk_blocks` is a **bespoke
post-order block walker** used by most passes (it descends into list items,
definition lists, and `content`-bearing blocks but treats `Header` specially); it
is distinct from Pandoc's own `pandoc.walk_block`.

`lua/pangu.lua` (CJK/Latin spacing) exists but is **not currently wired into
`filter.lua`** — it is dormant.

### Source lines (editor deep-linking)

Two passes cooperate to make rendered elements link back to their source line:
`source-line-preprocess.lua` (in the reader) tracks Markdown block state and emits
`<!-- pandocmd-source-line:N -->` comments; `source-lines.lua` (in the filter)
consumes those comments, sets `data-source-line` attributes, and inserts clickable
`zed://file…:N` links (rendered as `.source-line-link`). The source file path comes
from `doc.meta["pandocmd-source-file"]`. After parsing, the reader defensively removes
the reserved marker pattern from Math nodes so an unrecognized Markdown lexical
corner cannot corrupt rendered TeX.

### Section numbering

If any header carries the `appendix` class, the filter numbers sections itself
(`references.render_header_numbers`, alpha appendix numbering) and the writer sets
`number_sections = false`. Otherwise Pandoc's writer numbers them. The choice is
carried through `doc.meta["pandocmd-custom-section-numbers"]`.

### Asset resolution

The assets directory (containing `css/`, `templates/`, `math-macros.tex`,
`bib_style.csl`, fonts, katex) is resolved in this order:

1. `PANDOCMD_ASSETS_DIR` env var
2. `HAKYLL_PANDOCMD_ASSETS` env var
3. `pandocmd.assets-dir` in front matter (relative to the source file)
4. `assets` relative to the current directory

Other env vars: `PANDOCMD_TEMPLATE` overrides the template path;
`PANDOCMD_PREVIEW_LIVE_RELOAD_URL` makes the writer inject the live-reload script.

### Preview / live reload

`bin/pandocmd-preview` (fish, installed as `ppl`) builds the file to
`assets/preview/<hash>.html` — where `<hash>` is the first 16 hex chars of
`sha256(canonical absolute source path)`, so the URL is **stable per source path**,
not per contents.

Static files are served by a local **nginx** on port 80 (document root =
`assets/`, via the `/opt/homebrew/var/www/pandocmd` symlink; server block in
`nginx/pandocmd.conf`, deployed to `/opt/homebrew/etc/nginx/servers/`). nginx owns
the `127.0.0.1` host, applies per-path cache-control (preview HTML `no-store`,
fonts/KaTeX `immutable`, CSS `no-cache`), and proxies `/livereload` to the
live-reload hub.

`bin/pandocmd-preview-server.py` is that **hub**: a `SimpleHTTPRequestHandler`
subclass implementing the LiveReload official-7 WebSocket protocol at `/livereload`
plus a notify endpoint at `/__pandocmd/live-reload`. It runs as a **persistent,
self-daemonizing background process on `127.0.0.1:35729`** (double-fork + `setsid`,
`--daemon --pid-file --log-file`), decoupled from any single `ppl` run. `ppl`'s
`ensure_hub` starts it if absent and reuses it otherwise; it is **never killed on
`ppl` exit**, so `ws://127.0.0.1/livereload` is invariant and open browser tabs keep
reloading across repeated runs and across Ctrl-C of any one run. `ppl --stop` stops
it.

`ppl` uses `entr` to watch the source plus all `lua/`, `assets/templates/`,
`assets/css/`, `math-macros.tex`, and `bib_style.csl` files. On change it rebuilds
with `--build-only --notify-reload`, which POSTs to the hub's
`/__pandocmd/live-reload` (directly on port 35729, not through nginx); the hub
broadcasts a reload to every connected client. The browser does a **soft reload**:
it fetches the new HTML and swaps `.page-layout` innerHTML in place, keeping
fonts/KaTeX loaded and scroll position intact, then re-runs the content enhancers
(KaTeX render, section folding, cross-reference hover previews) defined in
`assets/templates/default.html`.

The template uses Merriweather for body text and KaTeX for math. Pandoc's KaTeX
HTML mode emits the TeX in `.math` spans, which the bundled client-side KaTeX
runtime renders directly without an intermediate MathML conversion.

## Conventions when editing

- Preserve the reader/filter/writer command order and the intra-filter pass order;
  cross-references silently break if links are computed after they are consumed.
- Filter passes generally return `blocks` (and sometimes a links map); mutate/replace
  via `util.walk_blocks` rather than Pandoc's walker to keep traversal semantics
  consistent with the rest of the pipeline.
- Generated `assets/preview/` output, `test/`, and `plan.md` are gitignored.
