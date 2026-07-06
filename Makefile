ROOT := $(CURDIR)

BIN_DIR ?= $(HOME)/.local/bin
FISH_COMPLETIONS_DIR ?= $(HOME)/.config/fish/completions

PPL_BIN := $(BIN_DIR)/ppl
PPL_SCRIPT := $(ROOT)/bin/pandocmd-preview
PPL_FISH_COMPLETION := $(FISH_COMPLETIONS_DIR)/ppl.fish
PPL_FISH_COMPLETION_SOURCE := $(ROOT)/completions/ppl.fish

.PHONY: help install link-bin link-fish-completion

help:
	@printf "%s\n" "Targets:"
	@printf "  %-22s %s\n" "install" "Link the ppl script and fish completion"
	@printf "  %-22s %s\n" "link-bin" "Link bin/pandocmd-preview to $(PPL_BIN)"
	@printf "  %-22s %s\n" "link-fish-completion" "Link completions/ppl.fish to $(PPL_FISH_COMPLETION)"

install: link-bin link-fish-completion

link-bin:
	@mkdir -p "$(BIN_DIR)"
	ln -sfn "$(PPL_SCRIPT)" "$(PPL_BIN)"

link-fish-completion:
	@mkdir -p "$(FISH_COMPLETIONS_DIR)"
	ln -sfn "$(PPL_FISH_COMPLETION_SOURCE)" "$(PPL_FISH_COMPLETION)"
