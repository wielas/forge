# Single command vocabulary. `make check` is THE definition of green (ADR-0003).
.PHONY: setup fmt lint test check hooks

setup:            ## install deps + git hooks
	uv sync
	uv run lefthook install || echo "lefthook not installed globally; uv tool install lefthook"

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
