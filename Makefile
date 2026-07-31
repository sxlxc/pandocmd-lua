ROOT := $(CURDIR)

BIN_DIR ?= $(HOME)/.local/bin
FISH_COMPLETIONS_DIR ?= $(HOME)/.config/fish/completions

PPL_BIN := $(BIN_DIR)/ppl
PPL_SCRIPT := $(ROOT)/bin/pandocmd-preview
PPL_FISH_COMPLETION := $(FISH_COMPLETIONS_DIR)/ppl.fish
PPL_FISH_COMPLETION_SOURCE := $(ROOT)/completions/ppl.fish

NGINX_PREFIX ?= /opt/homebrew
NGINX_SERVERS_DIR ?= $(NGINX_PREFIX)/etc/nginx/servers
NGINX_WEBROOT ?= $(NGINX_PREFIX)/var/www/pandocmd
NGINX_CONF := $(ROOT)/nginx/pandocmd.conf
NGINX_CONF_LINK := $(NGINX_SERVERS_DIR)/pandocmd.conf

.PHONY: help test install link-bin link-fish-completion install-nginx

help:
	@printf "%s\n" "Targets:"
	@printf "  %-22s %s\n" "install" "Link the ppl script and fish completion"
	@printf "  %-22s %s\n" "test" "Run the Lua regression tests under Pandoc"
	@printf "  %-22s %s\n" "link-bin" "Link bin/pandocmd-preview to $(PPL_BIN)"
	@printf "  %-22s %s\n" "link-fish-completion" "Link completions/ppl.fish to $(PPL_FISH_COMPLETION)"
	@printf "  %-22s %s\n" "install-nginx" "Symlink assets web root + nginx server block, then reload"

install: link-bin link-fish-completion

test:
	@pandoc --from markdown --to native --lua-filter=tests/source-line-preprocess.lua </dev/null >/dev/null
	@printf "%s\n" "source-line-preprocess tests passed"
	@pandoc --from markdown --to native --lua-filter=tests/algorithms.lua </dev/null >/dev/null
	@printf "%s\n" "algorithm tests passed"

link-bin:
	@mkdir -p "$(BIN_DIR)"
	ln -sfn "$(PPL_SCRIPT)" "$(PPL_BIN)"

link-fish-completion:
	@mkdir -p "$(FISH_COMPLETIONS_DIR)"
	ln -sfn "$(PPL_FISH_COMPLETION_SOURCE)" "$(PPL_FISH_COMPLETION)"

# Point nginx at the repo: web root -> assets/, server block -> nginx/pandocmd.conf.
# Both are symlinks, so edits to the tracked config apply on the next reload.
install-nginx:
	ln -sfn "$(ROOT)/assets" "$(NGINX_WEBROOT)"
	@mkdir -p "$(NGINX_SERVERS_DIR)"
	ln -sfn "$(NGINX_CONF)" "$(NGINX_CONF_LINK)"
	nginx -t && nginx -s reload
