ROOT := $(CURDIR)

PREVIEW_HOME ?= $(HOME)/.pandocmd-preview
BIN_DIR ?= $(HOME)/.local/bin
PREVIEW_CLI := $(ROOT)/bin/pandocmd-preview

.PHONY: help test test-browser install purge-previews

help:
	@printf "%s\n" "Targets:"
	@printf "  %-22s %s\n" "install" "Clean-copy the runtime to $(PREVIEW_HOME) and link the command"
	@printf "  %-22s %s\n" "test" "Run the Python and Lua regression suites"
	@printf "  %-22s %s\n" "test-browser" "Run Playwright browser regressions"
	@printf "  %-22s %s\n" "purge-previews" "Delete installed previews, media, diagnostics, and name mappings"

install:
	@python3 "$(PREVIEW_CLI)" --_install "$(ROOT)" "$(PREVIEW_HOME)" "$(BIN_DIR)"

purge-previews:
	@python3 "$(PREVIEW_CLI)" --_purge "$(PREVIEW_HOME)"

test:
	@python3 -m unittest discover -s tests -p 'test_*.py'
	@pandoc --from markdown --to native --lua-filter=tests/source-line-preprocess.lua </dev/null >/dev/null
	@printf "%s\n" "source-line-preprocess tests passed"
	@pandoc --from markdown --to native --lua-filter=tests/algorithms.lua </dev/null >/dev/null
	@printf "%s\n" "algorithm tests passed"

test-browser:
	npm run test-browser
