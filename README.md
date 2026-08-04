# pandocmd-lua

Pandoc Lua filters, templates, and assets for rendering Markdown to HTML, with
a local nginx-backed preview command for macOS.

## Requirements

Install Python 3, Pandoc, and nginx. The preview CLI uses only Python's standard
library; Fish, `entr`, `curl`, and `shasum` are not required.

```sh
brew install python pandoc nginx
```

nginx remains required for viewing generated previews. The build itself works
without nginx.

This runtime intentionally targets macOS. It does not open a browser, persist a
public hostname, package Linux/BSD variants, or redirect the old hash-only
preview URLs.

## Install

```sh
make install
```

This clean-copies the managed runtime to `~/.pandocmd-preview/` and creates one
command link at `~/.local/bin/pandocmd-preview`:

```text
~/.pandocmd-preview/
├── assets/
├── bin/pandocmd-preview
├── html/
│   └── media/
├── lua/
├── nginx/pandocmd.conf.example
└── state/
    ├── diagnostics/
    ├── previews.json
    ├── server.log
    ├── server.pid
    └── tmp/
```

Reinstalling replaces `assets/`, `bin/`, `lua/`, and `nginx/` from a clean
staging directory. It preserves generated `html/` and all `state/`. Only
declared runtime files are copied, so repository `.DS_Store` files, caches,
untracked files, and the ignored legacy `assets/preview/` directory cannot leak
into the installation.

The installer removes the old `ppl` and Fish-completion symlinks only when they
point to this project. It never removes unrelated files. Existing ignored HTML
under this checkout's `assets/preview/` is intentionally left alone; remove it
manually if it is no longer useful.

To explicitly delete installed HTML, copied media, diagnostics, and preview-name
mappings while retaining the installed runtime and daemon files:

```sh
make purge-previews
```

`PREVIEW_HOME` and `BIN_DIR` may be overridden when packaging or testing an
installation.

## One-time nginx setup

nginx setup is deliberately manual. `make install` never writes into nginx's
configuration directories and never reloads a service.

1. Open `~/.pandocmd-preview/nginx/pandocmd.conf.example` and replace every
   `__PANDOCMD_PREVIEW_HOME__` placeholder with the absolute installed path,
   normally `/Users/your-name/.pandocmd-preview`.
2. Copy the edited file to the nginx `servers/` include directory. Homebrew's
   Apple Silicon default is `/opt/homebrew/etc/nginx/servers/pandocmd.conf`.
3. Ensure the main `nginx.conf` includes `servers/*`, then test and reload:

```sh
nginx -t
nginx -s reload
```

Start the Homebrew service separately if necessary:

```sh
brew services start nginx
```

The example keeps port 80 and permits loopback plus Tailscale IPv4/IPv6 ranges.
It exposes only these routes:

- `/pandocmd-preview/assets/` serves installed styles, fonts, KaTeX, and other
  static assets.
- `/pandocmd-preview/<name>.html` and `/pandocmd-preview/media/` serve completed
  builds from the installed `html/` directory.
- `/pandocmd-preview/livereload` proxies WebSocket traffic to the persistent
  loopback daemon on port 35729.

Fonts and KaTeX receive immutable caching, CSS revalidates, and generated HTML
and media use `no-store`. The CLI always prints a localhost URL. A remote
Tailscale user can substitute the machine's Tailscale IP address or hostname.

Run the read-only configuration checks after nginx is configured:

```sh
pandocmd-preview --doctor
```

The doctor checks the installed layout, write access, Pandoc, daemon identity
and health, and nginx's asset and generated-preview routes. It reports a stopped
daemon as a warning; the next watching invocation starts it automatically.

## Previewing

```sh
pandocmd-preview path/to/main.md
```

A source such as `~/projectA/notes/main.md` receives a readable stable URL:

```text
http://127.0.0.1/pandocmd-preview/projectA-notes-main.html
```

Names come from the canonical path relative to the home directory. Unicode is
normalized, unsafe punctuation and whitespace become hyphens, and letter case
is preserved. Name ownership is atomically reserved under a file lock in
`state/previews.json`. A colliding source gets a short stable SHA-256 suffix.
Sources outside the home directory use only their basename plus a hash, so URLs
do not expose their containing system paths.

The terminal dashboard shows the URL, live-reload state, latest build result,
and captured Pandoc diagnostics. The polling watcher covers the source,
installed Lua/template/CSS/macro/CSL files, and local image dependencies. It
updates the dependency set after builds and notifies connected browser tabs only
after a successful publication. Ctrl-C or Ctrl-D exits the watcher without
stopping the shared daemon.

Useful modes:

```sh
pandocmd-preview --build-only path/to/main.md
pandocmd-preview --hash-only path/to/main.md
pandocmd-preview --port 8080 path/to/main.md
pandocmd-preview --stop
```

`--hash-only` retains the legacy 16-character canonical-path hash. `--port`
changes the public nginx port printed in the URL; live reload continues using
the fixed internal loopback port through nginx.

On first use, the CLI safely detects and replaces the old daemon recorded under
`/tmp`. New PID, log, temporary, diagnostic, and mapping files remain beneath
the installed `state/` directory. The daemon persists across CLI invocations,
supports concurrent browser tabs, and keeps existing tabs connected between
watch sessions.

### Local media

Standard Markdown/Pandoc image nodes that refer to local files are copied into a
per-preview staging directory and rewritten to `media/<preview-name>/...`.
Nested paths and spaces are supported. Remote, protocol-relative, fragment, and
`data:` targets remain external. A missing local image fails with a clear
diagnostic.

Pandoc writes HTML and copied media under `state/tmp/`; the CLI publishes them
only after the complete Pandoc process succeeds. A failed build therefore keeps
the last good HTML and media, and a later success removes stale media. Raw HTML
`<img>`, audio, and video resources are intentionally unchanged. The wrapper
does not use Pandoc's blanket `--extract-media`, which could fetch linked remote
resources.

## Direct Pandoc usage

The pipeline can still be invoked without the preview wrapper. Keep the reader,
filter, and writer in this order:

```sh
pandoc input.md \
  -f lua/reader.lua \
  -L lua/filter.lua \
  -t lua/writer.lua \
  -o output.html
```

Direct usage retains the existing root-relative asset URLs such as `/css/` and
`/fonts/`. The preview wrapper parameterizes them as
`/pandocmd-preview/assets/`; font files are referenced relative to
`css/fonts.css`, so both layouts work.

## Tests

```sh
make test
```

This runs the standard-library Python CLI/installer/integration tests followed
by the existing Pandoc-hosted Lua regressions.
