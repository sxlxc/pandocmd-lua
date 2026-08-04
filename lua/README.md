# pandocmd Pandoc Lua prototype

This directory contains a Lua reader/filter port of the document-processing
parts of the Hakyll pipeline.

Typical command:

```sh
pandoc main.md \
  -f lua/reader.lua \
  -L lua/filter.lua \
  -t lua/writer.lua \
  -o /tmp/pandocmd-pandoc.html
```

The reader does the pre-parse work that cannot be done by a normal AST filter:
source-line marker injection, theorem fence title normalization, and TeX macro
prepending. The filter ports equations, source-line labels, theorem/autoref
handling, sidenotes, stylesheet metadata, and citeproc metadata.
The writer applies the existing default HTML template with Hakyll-style literal
substitution, avoiding Pandoc template indentation changes for multiline fields.

`filter.lua` is only the Pandoc entrypoint. The individual passes live in
`source-line-preprocess.lua`, `equations.lua`, `source-lines.lua`,
`algorithms.lua`, `theorems.lua`, `sidenotes.lua`, `references.lua`, and
`page-meta.lua`, with shared helpers in `util.lua`.

Asset resolution uses this order:

1. `PANDOCMD_ASSETS_DIR`
2. `HAKYLL_PANDOCMD_ASSETS`
3. `pandocmd.assets-dir` relative to the source file
4. `assets` relative to the current directory

The generated public asset URL is independent of that filesystem path. It uses
`PANDOCMD_ASSET_BASE_URL`, then `pandocmd.asset-base-url`, and otherwise retains
the direct-build root-relative default. The preview CLI sets the base to
`/pandocmd-preview/assets`.

The final `media.lua` pass is inert for direct builds. When the preview CLI sets
its staging environment, the pass copies local Pandoc `Image` targets, rewrites
their URLs, and emits the dependency manifest consumed by the Python watcher.
