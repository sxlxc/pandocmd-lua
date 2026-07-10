# pandocmd-lua

Pandoc Lua filters, templates, and assets for rendering Markdown to HTML.

## Preview wrapper

`bin/pandocmd-preview` builds one Markdown file with the repo's Pandoc Lua
pipeline and writes the generated HTML to `assets/preview/<hash>.html`. The
static files are served by a local **nginx** on port 80 (document root = this
repo's `assets/` directory); live reload is a small **persistent hub daemon**
that nginx proxies at `/livereload`.

The preview hash is stable: it is derived from the source file's canonical
absolute path, not from file contents. Rebuilding the same source path reuses the
same preview URL.

Install the command-line dependencies with Homebrew:

```fish
brew install fish pandoc entr python nginx
```

Add the wrapper to your `PATH`, for example:

```fish
ln -sfn /path/to/pandocmd-lua/bin/pandocmd-preview ~/.local/bin/pandocmd-preview
```

### One-time nginx setup

Point nginx's document root at this repo's `assets/` and add the server block that
serves the preview and proxies the live-reload WebSocket. `nginx.conf` must
`include servers/*;` (the Homebrew default does), and nginx must be running on
port 80 (`brew services start nginx`). Then:

```fish
make install-nginx
```

That symlinks `assets/` to `/opt/homebrew/var/www/pandocmd`, symlinks
`nginx/pandocmd.conf` into `/opt/homebrew/etc/nginx/servers/`, and runs
`nginx -t && nginx -s reload`. Override `NGINX_PREFIX` if your Homebrew prefix
differs. The equivalent by hand:

```fish
ln -sfn /path/to/pandocmd-lua/assets /opt/homebrew/var/www/pandocmd
ln -sfn /path/to/pandocmd-lua/nginx/pandocmd.conf /opt/homebrew/etc/nginx/servers/pandocmd.conf
nginx -t && nginx -s reload
```

The server block serves `http://127.0.0.1/preview/...` from `assets/` (with
per-path cache-control) and proxies `/livereload` to the hub daemon on
`127.0.0.1:35729`. It claims only the `127.0.0.1` host, so a stock
`server_name localhost` block is left untouched.

### Previewing

```fish
pandocmd-preview path/to/main.md
```

The command builds once, logs the preview URL, ensures the live-reload hub is
running (starting it detached if needed, reusing it otherwise), watches the
source, Lua filters, templates, and CSS for rebuilds, and reloads the browser
over the nginx-proxied WebSocket when the preview HTML changes.

Because the hub is a persistent daemon on a fixed port — decoupled from any
single `pandocmd-preview` run — the WebSocket URL (`ws://127.0.0.1/livereload`)
never changes. Open browser tabs keep auto-reloading across repeated runs, and
Ctrl-C'ing one run does not tear down live reload for the others.

Useful modes:

```fish
pandocmd-preview --build-only path/to/main.md
pandocmd-preview --hash-only path/to/main.md
pandocmd-preview --stop                      # stop the live-reload hub daemon
```
