# pandocmd-lua

Pandoc Lua filters, templates, and assets for rendering Markdown to HTML.

## Preview wrapper

`bin/pandocmd-preview` builds one Markdown file with the repo's Pandoc Lua
pipeline, writes the generated HTML to `assets/preview/<hash>.html`, and serves
the shared `assets/` directory as the local preview document root.

The preview hash is stable: it is derived from the source file's canonical
absolute path, not from file contents. Rebuilding the same source path reuses the
same preview URL.

Install the small command-line dependencies with Homebrew:

```fish
brew install fish pandoc entr python
```

Add the wrapper to your `PATH`, for example:

```fish
ln -sfn /path/to/pandocmd-lua/bin/pandocmd-preview ~/.local/bin/pandocmd-preview
```

Preview a file:

```fish
pandocmd-preview path/to/main.md
```

The command builds once, starts a shared Python server rooted at this repo's
`assets/` directory if needed, logs the preview URL on the watch status line,
watches the source, Lua filters, templates, and CSS for rebuilds, and
auto-reloads the browser when the preview HTML changes.

Useful modes:

```fish
pandocmd-preview --build-only path/to/main.md
pandocmd-preview --hash-only path/to/main.md
pandocmd-preview --serve-only --port 8000
```
