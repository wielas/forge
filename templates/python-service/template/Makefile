# Single command vocabulary. `make check` is THE definition of green (ADR-0003).
.PHONY: setup fmt lint test check hooks

setup:            ## install deps + git hooks
	uv sync
	@git rev-parse --git-dir >/dev/null 2>&1 || { \
	  echo "not a git repo — run 'git init' first; hooks cannot be installed" >&2; exit 1; }
	uv run lefthook install
	@test -f "$$(git rev-parse --git-path hooks/pre-push)" || { \
	  echo "lefthook install reported success but no pre-push hook exists" >&2; exit 1; }

fmt:              ## auto-format
	uv run ruff format .
	uv run ruff check --fix .

lint:             ## no mutations
	uv run ruff format --check .
	uv run ruff check .

test:             ## full suite incl. BDD features, coverage floor enforced
	uv run pytest

check: lint test  ## THE green proof — CI runs exactly this
	@echo "FORGE CHECK: GREEN"
