# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
this repository.

## What this is

A custom Pandoc Markdown-to-HTML pipeline for math and academic documents,
implemented as Pandoc Lua reader, filter, and writer modules. It includes a
standard-library Python CLI for staged builds, dependency polling, and browser
live reload through a manually configured local nginx.

## Commands

The full Pandoc pipeline must keep this option order:

```sh
pandoc main.md -f lua/reader.lua -L lua/filter.lua -t lua/writer.lua -o out.html
```

Preview commands:

```sh
bin/pandocmd-preview path/to/main.md
bin/pandocmd-preview --build-only file.md
bin/pandocmd-preview --hash-only file.md
bin/pandocmd-preview --doctor
bin/pandocmd-preview --stop
```

Installation and tests:

```sh
make install
make purge-previews
make test
```

`make install` clean-copies managed runtime files to
`~/.pandocmd-preview/`, preserves its `html/` and `state/` directories, and
links `~/.local/bin/pandocmd-preview`. nginx setup is manual; use the installed
`nginx/pandocmd.conf.example`. Runtime dependencies are Python 3, Pandoc, and
nginx. Fish, `entr`, `curl`, and `shasum` are not used.

## Architecture

### Three-stage Pandoc pipeline

The pipeline is split across Pandoc's three extension points because each does
work the others cannot:

1. `lua/reader.lua` performs pre-parse text work. It parses YAML front matter,
   normalizes theorem fence titles, injects source-line markers, prepends shared
   and document TeX macros, calls `pandoc.read`, and stores source, asset
   filesystem path, and public asset-base metadata.
2. `lua/filter.lua` runs AST passes in dependency-sensitive order:
   equations, source lines, algorithms, theorems, cross-references, page
   metadata, section numbering, theorem/algorithm/sidenote rendering, paragraph
   unwrapping, citeproc, math punctuation, and finally preview media. Do not
   reorder these casually; later stages consume metadata produced earlier.
3. `lua/writer.lua` renders the body once and performs literal substitution into
   `assets/templates/default.html`. It does not use Pandoc's template engine,
   which would reindent multiline HTML. The writer also injects the optional
   live-reload client.

`lua/util.lua` contains shared helpers. `util.walk_blocks` is a bespoke
post-order block walker with project-specific list and nested-content semantics;
it is not interchangeable with Pandoc's normal walker. `lua/pangu.lua` exists
but is not currently wired into the filter.

### Source lines and numbering

`source-line-preprocess.lua` emits reserved comments before Markdown is parsed;
`source-lines.lua` consumes them, adds `data-source-line`, and creates editor
deep links. The reader strips leaked marker patterns from Math nodes as a safety
measure.

If any header carries the `appendix` class, the filter renders custom section
numbers and tells the writer not to number again. Otherwise Pandoc's HTML writer
does the numbering. The decision is carried in
`pandocmd-custom-section-numbers` metadata.

### Assets and media

The assets filesystem directory is resolved in this order:

1. `PANDOCMD_ASSETS_DIR`
2. `HAKYLL_PANDOCMD_ASSETS`
3. `pandocmd.assets-dir`, relative to the source
4. `assets`, relative to the current directory

`PANDOCMD_TEMPLATE` overrides the template. The public URL base is independent:
`PANDOCMD_ASSET_BASE_URL`, then `pandocmd.asset-base-url`, then the historical
root-relative default. The preview CLI uses `/pandocmd-preview/assets`.

`lua/media.lua` is a late, preview-only pass activated by staging environment
variables. It copies local Pandoc `Image` sources, rewrites their URLs beneath
`media/<slug>/`, and records dependencies for the watcher. Remote and data URLs
stay external; raw HTML media is intentionally untouched. Missing local media
must fail the build clearly.

### Preview runtime

`bin/pandocmd-preview` is both the public CLI and the hidden live-reload server.
It derives readable slugs from canonical home-relative source paths and reserves
them under a lock in `state/previews.json`. `--hash-only` separately preserves
the old 16-character canonical-path hash.

Every build writes HTML, copied media, and its dependency manifest beneath
`state/tmp/`. After Pandoc succeeds, the CLI swaps media and HTML into `html/`,
removes stale media, and only then notifies browsers. Failures preserve the last
good publication and update `state/diagnostics/<slug>.log`.

The Python poller watches the source, installed Lua/template/CSS/macro/CSL files,
and discovered media. The terminal dashboard captures diagnostics and exits
cleanly on Ctrl-C or Ctrl-D.

The same Python file exposes a persistent LiveReload official-7 WebSocket hub on
`127.0.0.1:35729`. PID and log files are `state/server.pid` and
`state/server.log`. It supports concurrent clients, survives watcher exit, and
is stopped explicitly with `--stop`. On first live use, the CLI safely cleans up
the identified legacy daemon recorded at `/tmp/pandocmd-livereload-35729.pid`.

nginx serves:

- `/pandocmd-preview/assets/` from installed `assets/`
- `/pandocmd-preview/<slug>.html` and `/pandocmd-preview/media/` from `html/`
- `/pandocmd-preview/livereload` as the only proxy route to the hub

The browser performs a soft reload by fetching the current HTML and replacing
`.page-layout`, preserving loaded fonts/KaTeX and scroll position before
re-running content enhancers.

## Conventions when editing

- Preserve reader/filter/writer command order and intra-filter pass order.
- Keep Lua helpers small, local, and consistent with `util.walk_blocks`.
- Preserve staged-publication rollback when changing the Python build path.
- Installer changes must not sweep ignored or arbitrary untracked files into the
  runtime and must preserve installed `html/` and `state/` on reinstall.
- nginx remains manual: Make targets must not write system nginx directories or
  reload services.
- Generated `html/`, `state/`, legacy `assets/preview/`, `test/`, and `plan.md`
  are gitignored.
