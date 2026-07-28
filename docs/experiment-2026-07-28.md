# Forge exercise ledger — operator outcome, not component count

The current test sequence is judged by the criteria the operator named:

1. **Operator time saved** — active human minutes avoided, compared with the
   same outcome without Forge. Automated wall time is recorded separately; a
   slower machine path can still be a win if it removes operator attention.
2. **Correction rate** — evaluated automation stages that required an operator
   or Forge change before the promised outcome held. Deliberate fault injection
   is excluded as a correction; failures of Forge's response to it count.
3. **Outcome quality** — whether the architecture boundary held and whether the
   final chunk/scenario would catch the promised failure. Each is rated 0–3
   with evidence, not inferred from green checks.

Forge does not currently emit active operator time. `n/a` below is deliberate:
card timestamps measure machine wall time, and polling a run is not the same as
attention required in a notification-driven steady state. The exercises record
terminal interventions exactly and will propose instrumentation after the
sample is large enough to know what to collect.

## Ledger

| Exercise | Automated wall evidence | Operator interventions after dispatch | Corrections / evaluated stages | Architecture quality | Chunk/scenario quality |
|---|---|---:|---:|---:|---:|
| Tier-2 approval | successful rerun `t_180c38a1`: 3m53s | 0 | 2/3 | 3 — human card sticky, unassigned, provenance verified by completion kernel | 3 — held implementation constant; normalized verdict provenance |
| Deliberate bounce | corrected prejudge `t_97716519`: 3m32s; worktree fix `t_d159a76e`: 56s; Codex role probe `t_d36ec44e`: 2m51s | 0 in each successful run | 3/3 | 2 — route and role proven; new clean-worktree guard is static/deployed but not yet live-proven | 3 — PR #6 now has a real assertion, with observed mutation failure |

### How to read the correction rate

These are adversarial commissioning runs designed to find seams, so 2/3 and
3/3 are not production defect estimates. They mean the tests are learning:

- Approval needed corrections for impossible unassigned tool use/sticky state,
  then for CLI creator provenance and fail-closed completion.
- Bounce needed corrections for scratch routing, then direct driver authorship,
  then a false clean-worktree proof that left `.orig`/`.rej` artifacts.

The files were moved intact to
`/private/tmp/forge-b1-leftovers-t_d36ec44e`; the PR worktree is clean.

## Missing baseline

Operator time **saved** remains `n/a` until one genuine idea is run both with a
recorded manual estimate and through Forge. For now the strongest evidence is
zero terminal interventions after dispatch on the successful approval, bounce,
and repair runs. Do not convert automated duration or tool-call count into
human minutes.
