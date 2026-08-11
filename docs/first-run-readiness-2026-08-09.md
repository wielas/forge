# Forge test-drive readiness — 2026-08-09

This reconciles `docs/audit-forgeboard-2026-07-30.md` with
`docs/roadmap-first-run.md`, the current `main` tree, and the live Mac mini. The
audit ledger is newer than the roadmap proposal, and executable evidence wins
over both when prose disagrees.

## Measured baseline

Checked from `/Users/goonlab/dev/forge` at `ed64867` (`origin/main`):

| Check | Result |
|---|---|
| `make validate` | OK |
| `make verify` | 231 passed / 0 failed / 3 skipped |
| `make preflight` | PASS 85 / WARN 3 / FAIL 0 |
| Open pull requests | none |
| Codex pin | live config, `forge-lane` §4 and `state.md` all say `gpt-5.6-sol` / `xhigh` |
| ADR-0011 samples | 0 post-gate reviews; the 10-review decision threshold is not met |
| Worktree sweep | 1 clean merged worktree is safely reclaimable; 17 non-main checkouts sit outside the bounded sweep |

The first sandboxed verify attempt was invalid because the suite deliberately
uses the live profile and uv-cache locations. The host-level rerun above is the
authoritative result and exactly matches the documented healthy baseline. The
three WARNs are expected: no global lefthook, an empty API-key placeholder, and
the historical `forge-ladder` board still selected as the current board.

Live versions have moved slightly beyond `docs/state.md`: Hermes 0.19.0,
Codex CLI 0.146.0, Claude Code 2.1.226, and GitHub CLI 2.97.0. The live flag
checks pass, so this is documentation drift rather than a compatibility failure.

## What is already done

The repair wave described as future work in the first-run roadmap has partly
landed and is green:

| Roadmap work | Current evidence | Disposition |
|---|---|---|
| D1a ledger reconciliation | PR #25; allocation table in the audit | done |
| D1e merge gate | `scripts/merge-gate.sh`; 16 `gate/` cases; preflight reads the live rule | done |
| A1 durable destination and bounded worktree sweep | `new-dest.sh`, `worktree-sweep.sh`; 29 `sweep/` cases | done |
| B1 WAL-safe snapshot primitive | `board-snapshot.sh`; metrics and preflight consume it | done |
| C1 plan-time sizing | `roadmap-check.sh`; 36 `roadmap/` cases; ADR-0012 | done but deliberately advisory |
| Canonical completed-run contracts | three schemas, producer registry, lane completion gate, 16 `metadata/` cases | fixture-proven; live proof still owed |
| Tier-1 program and derived routing | deterministic gate, programmatic driver, derived verdict routing | done; scorer-retirement experiment still data-blocked |
| Lane blast-radius boundary | setup/capture/final-audit programs and live Codex probe | done |

This closes the roadmap's A1, B1, C1, D1a and D1e implementation work. The
remaining pre-run work is therefore much smaller than the original proposal.

## Findings that can be closed before the test drive

| Finding or roadmap item | What remains | Planned chunk |
|---|---|---|
| F34, F36; D1b | execute skill-section references and the Codex pin agreement | CHUNK-1 |
| D1d `skill_manage` decision | Hermes 0.19 can disable the whole `skills` toolset, not only `skill_manage`; record retaining it behind `write_approval` | CHUNK-1 |
| F57; D1c | compare base and head `Touches` and report widening | CHUNK-2 |
| F91, F92, F93 | anchor help, make the consumer-side read-only assertion sidecar-aware, and inspect live boards deterministically | CHUNK-3 |
| F1, F2, F3 producer half, F26, F44 | add the explicit live metadata sweep, then prove it on the test drive | CHUNK-4 + run |
| F31, F48; D2 | expose exact driver usage and put operator touches in the generated retro row | CHUNK-5 |
| F14, F25, F53; C2 | emit and hash acceptance scenarios at plan time, then block in-branch rewrites | CHUNK-6 → CHUNK-7 |
| E1 staged launch | add safe `--root-only`, then a thin paid commissioning wrapper | CHUNK-8 → CHUNK-9 |
| F40, F81, F101, F103 | reconcile the ledger and operator docs after code lands | CHUNK-10 |

F103 is already substantively resolved: ADR-0012 D12.4 now contains the missing
plan-time incentive argument. F101 is also a decision rather than a code gap:
`reachable` is retained only to name stranded nodes after `acyclic` or
`single-root` fires. CHUNK-10 makes both dispositions explicit instead of
pretending they need new mechanisms.

The D2 discovery spike is complete. Hermes stamps `worker_session_id` into a
worker's own task metadata, and each profile `state.db` carries exact
`session_model_usage` rows: model, provider, API calls, input/output/cache and
reasoning tokens, estimated and actual cost fields, status and source.
Historical `forge-codex-lane` runs join exactly on that id. The value is
currently `estimated_cost_usd` with `cost_status=estimated`; missing actual cost
must remain visibly missing, never rewritten as zero.

## Work that must not be pulled into the pre-run sprints

These items are real, but their own decision rules say the run supplies the
input. Implementing them now would invent an answer or change a second variable:

- ADR-0011 / F4, F20, F35 and F58: the live board has 0 of the required 10
  post-gate reviews. Keep the pinned scorer unchanged.
- F6, F15, F21, F32, F33 and F38: incremental `claude -p --resume`, stable
  finding ids and the bounce budget all touch that pinned control arm.
- F10 and F52: wasted dependency dispatch is a dispatcher defect. Count it in
  the run; a PR-time gate cannot prevent it.
- F9, F16, F17, F22 and F46: signed-constraint restatement, tier-2 prompt
  generation, truthful titles, the clean model comparison and resolved model
  ids remain post-run changes. Hashes can freeze a source; they cannot decide
  whether new prose elsewhere restates that source more loosely.
- Timeout/reclaim, circuit-breaker recovery, Telegram approval and provider
  terms remain separate unknowns. Do not combine them with the product run.

The forgeboard-specific F12, F13, F15b, F23, F24, F54 and F59 remain moot as
product defects. Their methodology classes are already represented by live
Forge findings and are not separate chunks.

## Operational decisions and cleanup

One decision still blocks the test-drive repository: branch protection must be
available. On the current free plan a private repository returned 403, while a
public repository is proven to support the required PR plus `validate` and
`verify` checks. The recommended test-drive default is therefore a public repo;
the alternative is a paid plan that supports protection on private repos.
`make commission` must judge the actual gate and stay visibility-agnostic.

Worktree cleanup is not a code blocker. The bounded dry run found one automated
candidate at `.worktrees/s10-metadata-contract`. The 16 `forge-slices/*`
checkouts and one exercise checkout are intentionally refused. Review and remove
those explicitly after their branches are confirmed merged; do not widen the
unattended deletion boundary merely to make F80 disappear.

## Sprint sequence

| Sprint | Chunks | Exit condition |
|---|---|---|
| 1 — control-plane root | CHUNK-1 | pins, references and skill-write boundary are executable before more agents run |
| 2 — buy observability | CHUNK-4, CHUNK-5, CHUNK-6 in parallel | live metadata, driver telemetry and a frozen planning artifact exist |
| 3 — enforce and stage | CHUNK-7, then CHUNK-8 | acceptance cannot self-amend; one root card can be launched safely |
| 4 — commission and polish | CHUNK-9 with CHUNK-2 and CHUNK-3 | commissioning evidence is complete and deterministic gaps are closed |
| 5 — reconcile | CHUNK-10 | audit, state, roadmap and operator guide agree with the tree |

After Sprint 5: run `make roadmap-check PROJECT=<product>` until it is CLEAR,
run the paid commissioning command, bootstrap only the root, stop on a red live
metadata checkpoint, then bootstrap the rest. The complete operational sequence
stays in `docs/roadmap-first-run.md` until CHUNK-10 reconciles it with what
actually shipped.
