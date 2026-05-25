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
prepending. The filter ports equations, source-line labels, pangu spacing,
theorem/autoref handling, sidenotes, stylesheet metadata, and citeproc metadata.
The writer applies the existing default HTML template with Hakyll-style literal
substitution, avoiding Pandoc template indentation changes for multiline fields.

`filter.lua` is only the Pandoc entrypoint. The individual passes live in
`equations.lua`, `source-lines.lua`, `pangu.lua`, `theorems.lua`,
`sidenotes.lua`, `references.lua`, and `page-meta.lua`, with shared helpers in
`util.lua`.

Asset resolution uses this order:

1. `PANDOCMD_ASSETS_DIR`
2. `HAKYLL_PANDOCMD_ASSETS`
3. `pandocmd.assets-dir` relative to the source file
4. `assets` relative to the current directory
