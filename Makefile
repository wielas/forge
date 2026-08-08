# forge repo-level commands
.PHONY: install new validate verify preflight metrics prejudge

verify:                        ## execute this repo's own claims (see scripts/verify.sh)
	./scripts/verify.sh $(if $(SUITES),$(SUITES),) $(if $(WITH_CODEX),--with-codex,)

metrics:                       ## make metrics BOARD=<slug> [SINCE=..] [UNTIL=..] — the retro numbers, read-only
	@test -n "$(BOARD)" || { echo "usage: make metrics BOARD=<slug> [SINCE=YYYY-MM-DD] [UNTIL=YYYY-MM-DD]"; exit 1; }
	./scripts/metrics.sh $(BOARD) $(if $(SINCE),--since $(SINCE),) $(if $(UNTIL),--until $(UNTIL),)

# THIS BLOCKS (ADR-0009). Four checks block, three warn, and the severity map
# came from backtesting all 11 PRs of the run that produced the audit rather
# than from a table written in advance. Exit 1 is a block; exit 2 is the gate
# failing to run at all, and the two are deliberately different, because
# conflating them would let a network outage read as a rejection.
#
# It is tier 1's FIRST stage, not the whole of it. A clear result here is not an
# approval — the forge-prejudge SOUL runs its model scorer on whatever this lets
# through, and ADR-0007 D7.1 stands. The saving is real and is not a dollar
# saving: a blocked PR spends zero driver tokens, because nothing is spawned.
prejudge:                      ## make prejudge PR=<url|number> [REPO=owner/name] — tier 1 stage 1; exit 1 on a block
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
	@echo "   (where it succeeds, branch protection is the ONLY merge gate and the"
	@echo "    pre-push hook is advisory. It FAILS on a private repo on a free plan"
	@echo "    — 403 — and then the hook is your whole gate. Check, do not assume: F79)"

validate:                      ## sanity-check skill frontmatter + shell syntax
	@for f in skills/*/SKILL.md; do \
	  head -1 $$f | grep -q '^---$$' || { echo "BAD frontmatter: $$f"; exit 1; }; \
	  grep -q '^name:' $$f && grep -q '^description:' $$f || { echo "MISSING name/description: $$f"; exit 1; }; \
	done
	@bash -n install.sh hermes/board-bootstrap.sh hermes/profiles-bootstrap.sh \
	  scripts/preflight.sh scripts/metrics.sh scripts/verify.sh scripts/prejudge.sh \
	  scripts/lane-setup.sh scripts/lane-blast-radius.sh scripts/merge-gate.sh
	@python3 -c 'import ast; [ast.parse(open(f).read()) for f in ["scripts/prejudge-steps.py", "scripts/validate-metadata.py"]]'
	@echo "forge validate: OK"
