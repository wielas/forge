# forge repo-level commands
.PHONY: install new validate verify preflight metrics prejudge

verify:                        ## execute this repo's own claims (see scripts/verify.sh)
	./scripts/verify.sh $(if $(SUITES),$(SUITES),) $(if $(WITH_CODEX),--with-codex,)

metrics:                       ## make metrics BOARD=<slug> [SINCE=..] [UNTIL=..] — the retro numbers, read-only
	@test -n "$(BOARD)" || { echo "usage: make metrics BOARD=<slug> [SINCE=YYYY-MM-DD] [UNTIL=YYYY-MM-DD]"; exit 1; }
	./scripts/metrics.sh $(BOARD) $(if $(SINCE),--since $(SINCE),) $(if $(UNTIL),--until $(UNTIL),)

# SHADOW MODE. This gates nothing: no lefthook, no CI job, no lane or SOUL
# change, and `make verify`'s prejudge/gates-nothing case keeps it that way.
# Tier 1 costs a full Opus pass and has never bounced anything (17 runs, 0
# bounces) while tier 2 bounced 12 times on the same diffs from the same rubric.
# Everything tier 1 is mandated to catch is decidable without a model; this is
# that program, running beside the model tier rather than in place of it, until
# the numbers say which of its checks should gate (audit F35).
prejudge:                      ## make prejudge PR=<url|number> [REPO=owner/name] — tier 1 as a program, shadow mode
	@test -n "$(PR)" || { echo "usage: make prejudge PR=<url|number> [REPO=owner/name] [WAIT=secs]"; exit 1; }
	./scripts/prejudge.sh $(PR) $(if $(REPO),--repo $(REPO),) $(if $(WAIT),--wait $(WAIT),) $(if $(JSON),--json,)

preflight:                     ## revalidate the mini before unattended work (read-only)
	./scripts/preflight.sh $(if $(OUT),--out $(OUT),)

install:                       ## symlink skills into all harnesses
	./install.sh

# --defaults is not a convenience: without it copier demands a TTY, so this
# target could not run from a script, a CI job or an agent (measured
# 2026-07-28 — `make new` failed with "Interactive session required").
new:                           ## make new NAME=my-project [DEST=..]
	@test -n "$(NAME)" || { echo "usage: make new NAME=my-project [DEST=..]"; exit 1; }
	uvx copier copy templates/python-service $(or $(DEST),..)/$(NAME) --defaults \
	  --data project_name="$(NAME)"
	@# `-b main` is not a style preference: the pre-push guard, ci.yml's
	@# `push: branches: [main]` and `make protect` all hardcode main. On a host
	@# where init.defaultBranch is not main, plain `git init` yields a repo in
	@# which every one of those gates is silently inert.
	@echo "→ cd $(or $(DEST),..)/$(NAME) && git init -b main && make setup && claude (/scope)"
	@echo "→ then, once the GitHub repo exists: make protect"
	@echo "   (branch protection is the ONLY merge gate — the pre-push hook is advisory)"

validate:                      ## sanity-check skill frontmatter + shell syntax
	@for f in skills/*/SKILL.md; do \
	  head -1 $$f | grep -q '^---$$' || { echo "BAD frontmatter: $$f"; exit 1; }; \
	  grep -q '^name:' $$f && grep -q '^description:' $$f || { echo "MISSING name/description: $$f"; exit 1; }; \
	done
	@bash -n install.sh hermes/board-bootstrap.sh hermes/profiles-bootstrap.sh \
	  scripts/preflight.sh scripts/metrics.sh scripts/verify.sh scripts/prejudge.sh
	@python3 -c 'import ast,sys; ast.parse(open("scripts/prejudge-steps.py").read())'
	@echo "forge validate: OK"
