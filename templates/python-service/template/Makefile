# Single command vocabulary. `make check` is THE definition of green (ADR-0003).
.PHONY: setup fmt lint test check hooks protect

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

# CI is not a merge gate on its own — without branch protection a red PR can be
# merged, and the local pre-push guard is bypassable (`--no-verify`, or
# `git push origin HEAD:main` from a feature branch, which lefthook cannot see:
# it forwards the hook's args but NOT git's stdin, where the destination refs
# are). The only gate that holds off the host is this one. Run it once, after
# the GitHub repo exists.
protect:          ## make CI a real merge gate (run once, needs admin on the repo)
	@repo=$$(gh repo view --json nameWithOwner -q .nameWithOwner) || \
	  { echo "no GitHub repo yet — 'gh repo create' first" >&2; exit 1; }; \
	printf '%s' '{"required_status_checks":{"strict":true,"contexts":["check"]},' \
	  '"enforce_admins":true,' \
	  '"required_pull_request_reviews":{"required_approving_review_count":1},' \
	  '"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' \
	  | gh api -X PUT "repos/$$repo/branches/main/protection" --input - >/dev/null || \
	  { echo "branch protection FAILED (admin rights? private repo on a free plan?)" >&2; exit 1; }; \
	gh api "repos/$$repo/branches/main/protection" >/dev/null && \
	  echo "branch protection active on $$repo main: 'check' required, no force-push, no deletion"
