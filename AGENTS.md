# Repository Guidelines

## Project Structure & Module Organization

This repository implements a Pandoc Markdown-to-HTML pipeline. `lua/reader.lua`, `lua/filter.lua`, and `lua/writer.lua` are the three entry points; supporting transformations live beside them in `lua/` (for example, `equations.lua`, `theorems.lua`, and `references.lua`). Keep their execution order intact because later passes consume metadata produced by earlier ones.

Frontend resources are under `assets/`: the HTML template is in `assets/templates/`, stylesheets in `assets/css/`, and bundled fonts and KaTeX files in their respective subdirectories. The standard-library Python preview CLI lives in `bin/`, and the manual nginx example is in `nginx/`. Automated Python and Lua regression tests are in `tests/`. Generated previews under `html/` and `state/`, legacy previews under `assets/preview/`, and manual fixtures under `test/` are ignored.

## Build, Test, and Development Commands

- `make test` runs the Lua regression suite inside Pandoc.
- `pandoc input.md -f lua/reader.lua -L lua/filter.lua -t lua/writer.lua -o output.html` builds a document through the complete pipeline. The option order matters.
- `bin/pandocmd-preview --build-only input.md` builds one preview without watching.
- `bin/pandocmd-preview input.md` polls dependencies, rebuilds on changes, and triggers browser reload; it requires Python, Pandoc, and manually configured nginx.
- `make install` clean-copies the runtime to `~/.pandocmd-preview/` and links `pandocmd-preview` into `~/.local/bin`.

## Coding Style & Naming Conventions

Follow the surrounding file: Lua uses two-space indentation and `snake_case`; Python uses four spaces, with classes in `PascalCase`. Prefer small, single-purpose filter modules. Use `local` for Lua helpers and preserve the custom `util.walk_blocks` traversal semantics. No formatter or linter is configured, so avoid unrelated reformatting.

## Testing Guidelines

Add focused Lua regression cases to `tests/source-line-preprocess.lua`, using descriptive assertion names, and preview runtime coverage to `tests/test_preview.py`. Run `make test` for every change. For changes outside those suites, build a representative Markdown fixture and inspect the resulting HTML or live preview. There is no declared coverage threshold; prioritize edge cases involving parsing, math, source lines, local media, publication rollback, and cross-references.

## Commit & Pull Request Guidelines

Recent commits use short, imperative summaries such as `fix math macro bug` and occasionally a `fix:` prefix. Keep each commit scoped to one behavior. Pull requests should explain the user-visible effect, identify affected pipeline stages, and list verification commands. Link relevant issues and include before/after screenshots for template or CSS changes. Do not commit generated preview HTML.
