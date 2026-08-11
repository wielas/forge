# forge repo-level commands
.PHONY: install new validate verify preflight metrics metadata-live prejudge worktree-sweep roadmap-check

verify:                        ## execute this repo's own claims (see scripts/verify.sh)
	./scripts/verify.sh $(if $(SUITES),$(SUITES),) $(if $(WITH_CODEX),--with-codex,)

metrics:                       ## make metrics BOARD=<slug> [SINCE=..] [UNTIL=..] — the retro numbers, read-only
	@test -n "$(BOARD)" || { echo "usage: make metrics BOARD=<slug> [SINCE=YYYY-MM-DD] [UNTIL=YYYY-MM-DD]"; exit 1; }
	./scripts/metrics.sh $(BOARD) $(if $(SINCE),--since $(SINCE),) $(if $(UNTIL),--until $(UNTIL),)

metadata-live:                 ## make metadata-live BOARD=<slug> SINCE=<RFC3339> — opt-in completed-run contract sweep
	./scripts/metadata-live.sh "$(BOARD)" --since "$(SINCE)"

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

# THIS DOES NOT BLOCK, and that is the decision, not an omission (ADR-0012).
# It is prejudge's sizing rules read off the plan instead of off a diff, at the
# one moment the contract is still free to edit and no model has been spawned.
# F53: `size-budget` fires on 11 of 11 PRs of the only real run — correct every
# time, and every time after the money was spent. A gate that blocks everything
# is not a filter either, so this warns; blocking is a later recorded decision
# taken after a real roadmap has been fixed until it passes.
roadmap-check:                 ## make roadmap-check PROJECT=<abs-path> — the sizing rules, at plan time; advisory
	@test -n "$(PROJECT)" || { echo "usage: make roadmap-check PROJECT=<abs-path> [VERBOSE=1]"; exit 1; }
	./scripts/roadmap-check.sh "$(PROJECT)" $(if $(VERBOSE),--verbose,)

preflight:                     ## revalidate the mini before unattended work (read-only)
	./scripts/preflight.sh $(if $(OUT),--out $(OUT),)

install:                       ## symlink skills into all harnesses
	./install.sh

# --defaults is not a convenience: without it copier demands a TTY, so this
# target could not run from a script, a CI job or an agent (measured
# 2026-07-28 — `make new` failed with "Interactive session required").
#
# DEST is REQUIRED and absolute. It used to default to `..`, which is how the
# first real product the Forge built ended up in /private/tmp — purged by macOS,
# unindexed by Spotlight, 41 commits behind origin when a filesystem sweep
# finally found it (F19). scripts/new-dest.sh resolves symlinks AND `..` before
# judging, so /tmp and /private/tmp are the same refusal, and so is a path that
# only reaches them through a component that does not exist yet.
#
# NAME goes THROUGH the guard rather than around it. Validating DEST and then
# appending NAME to it is not validating what gets stamped:
# `NAME=../../../private/tmp/x` defeated the entire slice by typing the other
# variable. The guard prints the final target and this recipe uses that string,
# so there is no second place where the path is assembled.
#
# The chain is `&&`, not `;`. With `;` the recipe line's exit status was
# `echo`'s, so a copier that failed still printed "→ cd <dir>" for a directory
# that was never created, and `make` exited 0.
new:                           ## make new NAME=my-project DEST=$HOME/dev
	@test -n "$(NAME)" || { echo "usage: make new NAME=my-project DEST=\$$HOME/dev"; exit 1; }
	@target="$$(./scripts/new-dest.sh "$(DEST)" --name "$(NAME)")" || exit 1; \
	uvx copier copy templates/python-service "$$target" --defaults \
	  --data project_name="$(NAME)" \
	  && echo "→ cd $$target && git init -b main && make setup && claude (/scope)"
	@# `-b main` is not a style preference: the pre-push guard, ci.yml's
	@# `push: branches: [main]` and `make protect` all hardcode main. On a host
	@# where init.defaultBranch is not main, plain `git init` yields a repo in
	@# which every one of those gates is silently inert.
	@echo "→ then, once the GitHub repo exists: make protect"
	@echo "   (where it succeeds, branch protection is the ONLY merge gate and the"
	@echo "    pre-push hook is advisory. It FAILS on a private repo on a free plan"
	@echo "    — 403 — and then the hook is your whole gate. Check, do not assume: F79)"

# Dry-run by default: with no APPLY it prints and changes nothing. It only ever
# reaches worktrees under <project>/.worktrees/, only removes ones that are
# clean with a merged PR on the remote, and deletes branches with `git branch
# -d` — never -D, because that refusal is what stands between an unpushed
# commit and nothing. See state.md gap #1 / audit F18.
#
# `$(if $(APPLY),…)` is a NON-EMPTY test, not a truth test, so APPLY=0,
# APPLY=false and APPLY=no all passed --apply and deleted things — and APPLY=0
# is how an operator writes "don't". The flag is now `$(filter 1,…)`, and any
# other non-empty value is REFUSED rather than reinterpreted: silently doing the
# opposite of what was typed is worse than an error, on a command that removes
# worktrees and deletes branches.
worktree-sweep:                ## make worktree-sweep PROJECT=<abs-path> [APPLY=1] — reclaim merged chunk worktrees
	@test -n "$(PROJECT)" || { echo "usage: make worktree-sweep PROJECT=<abs-path> [APPLY=1]"; exit 1; }
	@case "$(APPLY)" in ""|1) ;; *) echo "make worktree-sweep: APPLY='$(APPLY)' is not understood. The only value that acts is APPLY=1; omit it entirely for a dry run."; exit 1;; esac
	./scripts/worktree-sweep.sh "$(PROJECT)" $(if $(filter 1,$(APPLY)),--apply,)

validate:                      ## sanity-check skill frontmatter + shell syntax
	@for f in skills/*/SKILL.md; do \
	  head -1 $$f | grep -q '^---$$' || { echo "BAD frontmatter: $$f"; exit 1; }; \
	  grep -q '^name:' $$f && grep -q '^description:' $$f || { echo "MISSING name/description: $$f"; exit 1; }; \
	done
	@bash -n install.sh hermes/board-bootstrap.sh hermes/profiles-bootstrap.sh \
	  scripts/preflight.sh scripts/metrics.sh scripts/verify.sh scripts/prejudge.sh \
	  scripts/lane-setup.sh scripts/lane-blast-radius.sh \
	  scripts/new-dest.sh scripts/worktree-sweep.sh scripts/board-snapshot.sh \
	  scripts/roadmap-check.sh scripts/touches-exempt.sh scripts/merge-gate.sh \
	  scripts/metadata-live.sh
	@python3 -c 'import ast; [ast.parse(open(f).read()) for f in ["scripts/prejudge-steps.py", "scripts/validate-metadata.py"]]'
	@echo "forge validate: OK"
