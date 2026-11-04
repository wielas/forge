# S8 opening brief — offline preparation

This is a proposed brief, not an opened session, implementation, approval to
launch, or a claim that S7 is complete. Reconcile it with S7's final evidence
and the epic parking lot when S8 actually opens. The epic session table remains
the progress record.

## Scope and acceptance to establish at opening

S8 owns MS3, MS4, MS5, GW3 and WL1, plus MS2's conversion of probe findings
to chunk cards (`docs/epic-hands-free.md`, session S8). Its opening must define
testable done-when clauses and map each to verification before implementation:

- **MS3:** an overseer handles gate cards, exceptions and triage, not each
  chunk, with usage recorded per invocation.
- **MS4 and MS2:** a milestone checkpoint reports delivered requirements, probe
  results, cost against estimate, follow-ups and next milestone; exercise pass,
  failed probe and cost-overrun decisions, including whether a finding is a
  product defect or a probe defect. Rehearse it against completed M1 before B.
- **MS5:** provide an accountable triage and contract-amendment path, including
  acceptance re-freeze and a decision record; the epic's stated done-when is
  empty triage at every checkpoint.
- **GW3:** restrict actionable replies to the operator's paired chat and
  allowlisted scripts, covering the decisions named by the epic.
- **WL1:** consider retiring the tier-1 scorer only if the flip criterion is
  met; retain the deterministic gate. A supplemental test is not automatically
  equivalent to Run A's pre-registered seed.
- Close or explicitly disposition P9 and P10(4)–(5) before merge mode; triage
  P14 and the S7 findings within their documented scope. Record the baseline,
  each test's red/green and mutation evidence, and the operator's deployment
  steps in the actual S8 brief.

## Dependencies and boundaries

S7 closes only after its five cards are done with merged PRs, the M1 probe has
run, seven digests are judged, and its end-of-run evidence is recorded. GATE-M1
stays held through S8 and is completed in S9, after the checkpoint rehearsal.
The original S-1 is currently not evidenced or credited; the flip is pending,
so Run B remains shadow by default. The product's own GATE-M1 conditions and
post-spike planning record also remain prerequisites for releasing M2.

Offline design and tests can be prepared in a separate bounded slice without
changing the deployed runtime, board, jobs, or frozen Run A protocol. S8's
actual opening follows the epic's clean baseline and session brief procedure;
its live checkpoint rehearsal and any deploy are operator actions after S7
closeout. Nothing in this document approves a service change, gate release or
merge-authority flip.
