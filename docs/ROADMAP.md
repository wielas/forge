# Roadmap — Forge test-drive readiness

Derived from `docs/first-run-readiness-2026-08-09.md`. Milestones are ordered by
integration risk: establish the control-plane root, build observability, freeze
acceptance, commission the staged launch, then reconcile documentation.

## Progress

- **CHUNK-1:** done 2026-08-09 — implementation and live `gpt-5.6-sol` / `xhigh`
  conformance proof complete; profile bootstrap remains the documented
  post-merge operation.
- **CHUNK-2:** done 2026-08-09 — prejudge reports advisory head-minus-base
  `Touches` widening, with recorded fixtures covering additions, removals,
  unchanged contracts, and the shared process-document exemption.
- **CHUNK-3:** done 2026-08-10 — help extraction is content-anchored,
  read-only metrics fingerprint every SQLite sidecar, all live boards are
  checked in stable named order, and reachability is diagnostic evidence.
- **CHUNK-5:** done 2026-08-10 — exact profile/session joins expose driver
  totals and every model row, missing usage stays unjudged, and generated retro
  rows carry operator touches plus driver coverage with honest cost status.
- **CHUNK-6:** done 2026-08-10 — roadmap emits contract-matched Gherkin,
  requires real-source coverage, and freezes every acceptance file by SHA-256
  before implementation begins.
- **CHUNK-7:** done 2026-08-10 — prejudge compares implementation features and
  their manifest against the approved PR base, blocks self-amendment, preserves
  the separate planning-PR escape hatch, and keeps `@real-source` in judging.

### CHUNK-1: Enforce methodology references and runtime pins
- **Goal:** Make section references, the Codex pin, and the retained `skill_manage` boundary executable claims before more unattended work runs.
- **Milestone:** M1 · **Depends on:** none
- **Serves:** F34, F36 · **Relevant ADRs:** 0002, 0003, 0005
- **Touches:** `scripts/verify.sh`, `skills/end-chunk/SKILL.md`, `hermes/profiles-bootstrap.sh`, `docs/open-questions.md`, `docs/adr/0013-lane-skill-management.md`
- **Scenarios:**
  - Given every `<skill> §<n>` reference in a Forge skill, When the CLI suite runs, Then each target heading resolves in the named skill.
  - Given a referenced section is renamed, When the CLI suite runs, Then it fails and names the source reference and missing heading.
  - Given the two checked-in Codex pin statements agree, When the offline CLI suite runs, Then it passes without reading a home-directory config.
  - Given the live Codex pin differs from the checked-in model-and-effort pair, When the config suite runs, Then it fails and prints both values.
  - Given Hermes cannot disable only `skill_manage`, When the profile policy is read, Then the ADR retains the `skills` toolset behind enforced `skills.write_approval=true` and names the residual staged-write capability.
- **Acceptance:** tests/features/chunk_1.feature
- **Out of scope:** changing the Codex invocation, changing the model pin, disabling the whole `skills` toolset, or changing a SOUL.
- **Done when:** `make validate` and `make verify` are green, the scenarios pass, docs are updated, and `profiles-bootstrap.sh` is run after merge because its generated config text changed.
- **Lane:** forge-codex-lane · **Risk:** low

### CHUNK-2: Report in-branch Touches widening
- **Goal:** Make the advisory `touches` result reveal when a PR expands its own contract instead of certifying the expanded contract as unchanged.
- **Milestone:** M5 · **Depends on:** CHUNK-1
- **Serves:** F57 · **Relevant ADRs:** 0003, 0009, 0012
- **Touches:** `scripts/prejudge.sh`, `scripts/verify.sh`, `scripts/fixtures/prejudge-prs/`, `docs/adr/0009-tier-1-gate.md`
- **Scenarios:**
  - Given the head contract adds a path absent from the base contract, When prejudge runs, Then `touches-widened` warns with that path even when the implementation diff is inside the head list.
  - Given the head contract removes a path, When prejudge runs, Then the removal is not reported as widening.
  - Given the contract is unchanged and the implementation stays inside it, When prejudge runs, Then both `touches` and `touches-widened` pass.
  - Given a process-doc exemption is added to `Touches`, When prejudge compares the contracts, Then the shared exemption policy is applied and no second exemption list is introduced.
- **Acceptance:** tests/features/chunk_2.feature
- **Out of scope:** making `Touches` blocking, reading only the base contract for scope, or changing the six-path planning cap.
- **Done when:** `make validate` and `make verify` are green, recorded-PR fixtures exercise the scenarios, and the ADR documents the advisory meaning.
- **Lane:** forge-codex-lane · **Risk:** medium

### CHUNK-3: Make diagnostics deterministic and sidecar-aware
- **Goal:** Remove the remaining false-confidence paths in help extraction, SQLite read-only checks, live-board selection, and graph diagnostics.
- **Milestone:** M5 · **Depends on:** CHUNK-1
- **Serves:** F91, F92, F93, F101 · **Relevant ADRs:** 0003, 0012
- **Touches:** `scripts/verify.sh`, `scripts/preflight.sh`, `scripts/roadmap-check.sh`, `docs/hermes-field-notes.md`, `docs/adr/0012-sizing-at-plan-time.md`
- **Scenarios:**
  - Given a new verify suite is appended, When `verify.sh --help` runs, Then the complete group list is printed without line-number pins.
  - Given preflight's header grows, When `preflight.sh --help` runs, Then its Usage and Exit sections remain complete.
  - Given an end-to-end metrics read creates a WAL sidecar, When the read-only case compares the source set, Then it fails even if `kanban.db` bytes are unchanged.
  - Given multiple live boards exist, When the live-schema check runs, Then every selected board is named and checked deterministically rather than choosing `ls | head -1`.
  - Given a finite acyclic graph has one root, When `reachable` reports pass, Then ADR-0012 identifies it as diagnostic evidence and not an independent detector.
- **Acceptance:** tests/features/chunk_3.feature
- **Out of scope:** opening live boards read-write, adding live access to CI, or removing the single-root requirement.
- **Done when:** `make validate` and `make verify` are green, the scenarios pass under mutations, and the field notes describe the live-board policy.
- **Lane:** forge-codex-lane · **Risk:** low

### CHUNK-4: Add a scoped live metadata sweep
- **Goal:** Validate completed producer rows and model-authored block reasons from a WAL-safe board snapshot with honest valid, invalid, and unjudged counts.
- **Milestone:** M2 · **Depends on:** CHUNK-1
- **Serves:** F1, F2, F26, F44 · **Relevant ADRs:** 0003, 0009
- **Touches:** `scripts/metadata-live.sh`, `scripts/validate-metadata.py`, `scripts/verify.sh`, `Makefile`, `rubrics/kanban-metadata-schema.md`, `docs/operator-guide.md`
- **Scenarios:**
  - Given no RFC3339 `SINCE` value, When `make metadata-live` runs, Then it refuses before reading a board.
  - Given post-cutoff completed rows from every contracted profile, When the sweep runs, Then valid envelopes are counted by profile and schema.
  - Given a board contains nested metadata, null metadata, and a cross-profile envelope, When the sweep runs, Then every bad row is named and classified as invalid or unjudged.
  - Given a model-authored block reason outside `blocked_reason_pattern`, When the sweep runs, Then it fails and prints the task, run, and reason.
  - Given rows predate `SINCE`, When the sweep runs, Then they are ignored and reported separately from valid rows.
- **Acceptance:** tests/features/chunk_4.feature
- **Output contract:** Print `valid`, `invalid`, `unjudged`, and `ignored` counts; exit 0 only when post-cutoff expected producers are present and every judged item is valid, exit 1 on a contract violation, and exit 2 when the sweep cannot read or scope its source.
- **Out of scope:** adding a live board to default `make verify`, normalizing historical envelopes, or treating unreadable rows as valid.
- **Done when:** `make validate` and `make verify` are green, fixtures cover every classification, the command reads through `board-snapshot.sh`, and operator docs are updated.
- **Lane:** forge-codex-lane · **Risk:** medium

### CHUNK-5: Join exact driver usage into retro metrics
- **Goal:** Use trusted worker session ids to report metered-driver usage and operator touches without inventing missing cost.
- **Milestone:** M2 · **Depends on:** CHUNK-1
- **Serves:** F31, F48 · **Relevant ADRs:** 0003, 0004, 0005
- **Touches:** `scripts/metrics.sh`, `scripts/verify.sh`, `scripts/fixtures/metrics-board.sql`, `scripts/fixtures/metrics-expected.json`, `docs/hermes-field-notes.md`, `docs/retro-metrics.md`
- **Scenarios:**
  - Given a chunk run has a trusted `worker_session_id`, When metrics joins its profile state, Then model, provider, API calls, tokens, cache use, and cost status come from the exact session row.
  - Given a run lacks `worker_session_id`, When metrics runs, Then it is counted as unjudged rather than assigned zero usage.
  - Given a profile state database is unavailable, When metrics runs, Then base metrics remain readable and the driver-usage limitation is explicit.
  - Given Hermes reports estimated cost with no actual cost, When metrics renders output, Then the estimate is labelled estimated and actual cost remains absent.
  - Given `--markdown-row`, When metrics renders the retro row, Then operator touches and driver-usage coverage have dedicated cells generated by the script.
- **Acceptance:** tests/features/chunk_5.feature
- **Measured seam:** Join `task_runs.metadata.worker_session_id` and `task_runs.profile` to `$HERMES_HOME/profiles/<profile>/state.db`; snapshot both SQLite sources, use `sessions` for per-session totals, and preserve every `session_model_usage` row as the per-model breakdown.
- **Out of scope:** stamping model-authored cost into `forge.chunk.v1`, changing `forge.judge.v1`, or editing the pinned scorer.
- **Done when:** `make validate` and `make verify` are green, exact and missing joins are fixture-proven, the generated row matches the log header, and field notes record the substrate contract.
- **Lane:** forge-codex-lane · **Risk:** medium

### CHUNK-6: Emit and hash acceptance at planning time
- **Goal:** Make `/roadmap` emit executable feature files and a hash manifest before implementation begins.
- **Milestone:** M3 · **Depends on:** CHUNK-1
- **Serves:** F14, F25, F53 · **Relevant ADRs:** 0003, 0012, 0014
- **Touches:** `skills/roadmap/SKILL.md`, `scripts/acceptance-freeze.sh`, `scripts/verify.sh`, `docs/adr/0014-frozen-acceptance.md`, `tests/features/`, `docs/first-run-readiness-2026-08-09.md`
- **Scenarios:**
  - Given a chunk contract, When `/roadmap` finishes, Then its `Acceptance` field names an existing `tests/features/chunk_<id>.feature` whose Given/When/Then steps match the contract.
  - Given a contract names an external source, When `/roadmap` finishes, Then its feature file contains a `@real-source` scenario.
  - Given all planned feature files exist, When the freeze command runs, Then it writes deterministic path and SHA-256 entries to `contract-freeze.json`.
  - Given a missing feature file, When the freeze command runs, Then it fails and names the chunk and expected path.
- **Acceptance:** tests/features/chunk_6.feature
- **Freeze format:** Each chunk gains `**Acceptance:** tests/features/chunk_<id>.feature`; `docs/chunks/contract-freeze.json` maps each repo-relative feature path to its SHA-256 digest.
- **Stop rule:** If C2 accumulates two tier-2 bounces before both halves are independently green, park CHUNK-6 and CHUNK-7, keep C1 advisory, and run with F14/F25 still open rather than shipping a half-built freeze.
- **Out of scope:** implementing step definitions, enforcing the hashes on a PR, mutation testing, or changing old project contracts.
- **Done when:** `make validate` and `make verify` are green, the scenarios pass, ADR-0014 records the amendment mechanism, and the roadmap skill emits all artifacts from one planning pass.
- **Lane:** claude-interactive · **Risk:** high (docker backend)

### CHUNK-7: Enforce frozen acceptance during implementation
- **Goal:** Block implementation PRs that rewrite planned acceptance while preserving a human planning-PR amendment path.
- **Milestone:** M3 · **Depends on:** CHUNK-6
- **Serves:** F14, F25, F53 · **Relevant ADRs:** 0003, 0009, 0012, 0014
- **Touches:** `scripts/acceptance-freeze.sh`, `scripts/prejudge.sh`, `scripts/verify.sh`, `skills/start-chunk/SKILL.md`, `skills/judge/SKILL.md`, `templates/python-service/template/AGENTS.md.jinja`
- **Scenarios:**
  - Given a feature file hash differs from the planning manifest, When prejudge runs on an implementation PR, Then it blocks and names the changed file.
  - Given only step definitions are added, When prejudge runs, Then the frozen-feature check passes.
  - Given an implementation PR changes a feature and its manifest entry together, When prejudge compares both against main, Then the self-amendment still blocks.
  - Given acceptance genuinely needs amendment, When a human planning PR updates the feature and manifest on main, Then a later implementation branch can start from the new hash.
  - Given a frozen contract names an external source, When judge reviews it, Then the `@real-source` scenario remains part of the scored acceptance surface.
- **Acceptance:** tests/features/chunk_7.feature
- **Stop rule:** If C2 accumulates two tier-2 bounces before both halves are independently green, park CHUNK-6 and CHUNK-7, keep C1 advisory, and run with F14/F25 still open rather than shipping a half-built freeze.
- **Out of scope:** letting an implementation PR update its own manifest, semantic grading by hash, or blocking ordinary step-definition work.
- **Done when:** `make validate` and `make verify` are green, positive and negative scenarios pass, the template documents the boundary, and the escape hatch requires a separate human planning PR.
- **Lane:** claude-interactive · **Risk:** high (docker backend)

### CHUNK-8: Bootstrap only the validated root card
- **Goal:** Add an idempotent `--root-only` mode that validates a single-root graph before creating the staged launch card.
- **Milestone:** M4 · **Depends on:** CHUNK-4, CHUNK-7
- **Serves:** E1, E2, E3 · **Relevant ADRs:** 0003, 0008, 0012
- **Touches:** `hermes/board-bootstrap.sh`, `scripts/verify.sh`, `.github/workflows/verify.yml`, `docs/operator-guide.md`, `docs/state.md`
- **Scenarios:**
  - Given a valid graph with one root, When bootstrap runs with `--root-only`, Then it creates only that root card.
  - Given a graph has multiple roots, When root-only bootstrap runs, Then it fails before any card is created.
  - Given root-only already created the root, When full bootstrap runs, Then the same idempotency key maps the root and every remaining parent is attached atomically.
  - Given root-only mode, When parent-count reconciliation runs, Then it checks the created set without weakening full mode's declared-edge assertion.
- **Acceptance:** tests/features/chunk_8.feature
- **Out of scope:** changing dispatcher scheduling, creating stacked branches, bypassing `roadmap-check`, or bootstrapping the product before the metadata checkpoint is green.
- **Done when:** `make validate` and `make verify` are green, the real script passes stubbed Hermes scenarios, CI runs the group, and staged-launch docs are updated.
- **Lane:** forge-codex-lane · **Risk:** medium

### CHUNK-9: Commission a product run with existing gates
- **Goal:** Provide a paid, non-mutating commissioning command that records every prerequisite result before a board is allowed to spend.
- **Milestone:** M4 · **Depends on:** CHUNK-4, CHUNK-5, CHUNK-8
- **Serves:** F102, E1, E2, E6 · **Relevant ADRs:** 0003, 0004, 0008, 0012
- **Touches:** `scripts/commission.sh`, `Makefile`, `scripts/verify.sh`, `.github/workflows/verify.yml`, `docs/operator-guide.md`, `docs/state.md`
- **Scenarios:**
  - Given a clean durable project with a protected remote, When `make commission` runs, Then it executes the paid Codex probe, preflight, roadmap check, and launch prerequisites into one timestamped report.
  - Given a prerequisite exits nonzero, When commissioning finishes, Then the report names that check and the command exits nonzero.
  - Given roadmap-check emits advisory warnings, When commissioning records it, Then the report preserves WARN rather than relabelling it PASS.
  - Given the repository is private without an enforceable merge gate, When commissioning checks protection, Then it refuses regardless of repository visibility labels.
  - Given commissioning succeeds, When the operator inspects the project, Then tracked files and the board are unchanged and evidence lives under ignored `.forge/` state.
- **Acceptance:** tests/features/chunk_9.feature
- **Command contract:** Run from the Forge checkout with `PROJECT=<absolute product path>` and `BOARD=<slug>`; record `make verify WITH_CODEX=1`, `make preflight`, the product's roadmap check, durable-path and clean-tree checks, remote resolution, and `merge-gate.sh` into `$PROJECT/.forge/commission-<UTC>.md` without calling Hermes board mutation commands.
- **Out of scope:** creating a repository, changing visibility, creating cards, running the product graph, or inventing new pass criteria inside the wrapper.
- **Done when:** `make validate` and `make verify` are green, command stubs cover every exit path, one intentional paid probe is recorded on the mini, and the operator guide names the cost.
- **Lane:** forge-codex-lane · **Risk:** medium

### CHUNK-10: Reconcile the launch ledger and operator contract
- **Goal:** Make the audit, first-run roadmap, current state, and operator guide agree with the code and measured pre-launch evidence.
- **Milestone:** M5 · **Depends on:** CHUNK-2, CHUNK-3, CHUNK-9
- **Serves:** F40, F81, F101, F103 · **Relevant ADRs:** 0002, 0003, 0012
- **Touches:** `docs/audit-forgeboard-2026-07-30.md`, `docs/roadmap-first-run.md`, `docs/state.md`, `docs/operator-guide.md`
- **Scenarios:**
  - Given every finding touched by this roadmap, When the ledger is reconciled, Then each status header agrees with executable evidence and names the closing chunk or remaining proof.
  - Given the old first-run roadmap mixes shipped and future work, When it is reconciled, Then landed tracks, remaining commands, and the operational run sequence are unambiguous.
  - Given F80's out-of-bound worktrees, When the operator guide describes cleanup, Then it preserves the bounded unattended sweep and requires explicit review outside that bound.
  - Given F81 and F103 have prior dispositions, When docs are updated, Then the record is preserved and a superseding decision is linked rather than silently rewriting history.
- **Acceptance:** tests/features/chunk_10.feature
- **Out of scope:** marking live-proof findings fixed before the run, deciding ADR-0011 without ten samples, deleting worktrees, or rewriting historical measurements.
- **Done when:** `make validate`, `make verify`, and `make preflight` match their recorded baselines, the roadmap checker is CLEAR, and all four documents point to the same next command.
- **Lane:** forge-codex-lane · **Risk:** low
