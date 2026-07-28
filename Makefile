# forge repo-level commands
.PHONY: install new validate verify preflight

verify:                        ## execute this repo's own claims (see scripts/verify.sh)
	./scripts/verify.sh $(if $(SUITES),$(SUITES),) $(if $(WITH_CODEX),--with-codex,)

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
	@echo "→ cd $(or $(DEST),..)/$(NAME) && git init && make setup && claude (/scope)"
	@echo "→ then, once the GitHub repo exists: make protect"
	@echo "   (branch protection is the ONLY merge gate — the pre-push hook is advisory)"

validate:                      ## sanity-check skill frontmatter + shell syntax
	@for f in skills/*/SKILL.md; do \
	  head -1 $$f | grep -q '^---$$' || { echo "BAD frontmatter: $$f"; exit 1; }; \
	  grep -q '^name:' $$f && grep -q '^description:' $$f || { echo "MISSING name/description: $$f"; exit 1; }; \
	done
	@bash -n install.sh hermes/board-bootstrap.sh hermes/profiles-bootstrap.sh scripts/preflight.sh
	@echo "forge validate: OK"
