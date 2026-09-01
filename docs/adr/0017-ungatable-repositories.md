# ADR-0017: "GitHub cannot gate this repository" is an answer, not a failure to ask

- Status: accepted
- Date: 2026-09-01
- Constrains: ADR-0003 (what a control may claim), F79/F110's merge gate.
- Reverses: `docs/operator-guide.md`'s refusal of any product without
  enforceable PR protection and a required `check` status.

## Context

Forge is about to drive several **private** product repositories on a **free**
GitHub plan. Branch protection and rulesets are paid features, so neither exists
there — and `scripts/merge-gate.sh` read that as "the question could not be
asked", exit 2. Exit 2 fails commissioning, so **no private product could be
commissioned at all**:

```
$ scripts/merge-gate.sh wielas/JobApp --branch main --require check
merge-gate: cannot read rulesets for wielas/JobApp (403, or no access).
  A control that could not run has NOT passed (F79). Confirm by hand.
exit=2
```

The repository was already inconsistent with itself about this. The root
`Makefile`'s `new` target tells the operator that `make protect` "FAILS on a
private repo on a free plan — 403 — and then the hook is your whole gate", while
the operator guide said such a product "is refused". One of those had to give.

### The measurement (2026-09-01, `wielas/JobApp`)

| Call | Result |
|---|---|
| `gh api repos/wielas/JobApp` | **200**, `"private": true` |
| `gh api --paginate .../rulesets` | **exit 1**, stderr below |
| `gh api .../branches/main/protection` | **exit 1**, same |
| `gh api repos/wielas/forge/rulesets` (public control) | **200**, `mainprotect` |

Both refusals carry GitHub's own sentence, on stderr, twice — once as `gh`'s
summary and once as the raw body:

```
gh: Upgrade to GitHub Pro or make this repository public to enable this
    feature. (HTTP 403)
{"message":"Upgrade to GitHub Pro or make this repository public to enable
 this feature.","status":"403"}
```

That is not "we lack permission to look". It is **"no such feature here"**. No
configuration can produce a gate on that repository, so no gate was missed. It
is strictly more information than exit 2, and it self-heals: upgrade the plan or
make the repository public and the check turns itself back on with no change to
any config file. **Capability, not visibility, is the discriminator** — a private
repository on a Pro or Team plan can be gated, and must still be checked.

## Decision

**D17.1 — A fifth verdict, `UNAVAILABLE`, exit 5.** Exits 0/2/3/4 keep their
meanings exactly. 5 says: the platform cannot gate this repository. It is never
reported as `GATED`, and it is not `NONE` (4) either — "no rule exists" and "no
rule *can* exist" are different facts and route differently.

**D17.2 — The rule is a conjunction, because the discriminator is prose.** The
sentinel is a GitHub-owned string, and this repo's recurring defect is a check
anchored to content that moves (F65/F66). So:

```
repos/{slug} readable  AND  .private == true
  AND the rulesets 403 carries the sentinel
  AND the classic-protection 403 carries the sentinel      -> 5
```

Anything less is **2**: a generic 403 (`Must have admin`), the sentinel on a
repository GitHub says is public, and one mechanism unavailable while the other
answers are all incoherent, and incoherent is UNKNOWN. `.private` is read from
the `repos/{slug}` response already in hand; there is no extra API call.

**D17.3 — The degrade direction is deliberate.** If GitHub rewords that sentence
this collapses to 2, and 2 still refuses commissioning. Losing the escape hatch
is safe; granting it wrongly is not. That direction is stated in the script
header so a future reader does not "fix" it.

**D17.4 — Exit 5 does not fail commissioning; exit 2 still does.** F65 governs
"could not ask" and always will. It does not govern "cannot be asked", which is
what 5 means. `REQUIRE_GATE=1` restores the strict posture for a product that
*should* be gated; only `1` acts and any other value is refused rather than
reinterpreted, because an operator who types `REQUIRE_GATE=true` and silently
gets the lenient path has been told the opposite of what they asked.

**D17.5 — Every commissioning report states its posture.** `## result` carries a
mandatory `posture:` line beside `overall:`, emitted on every path from the merge
gate's own exit and nothing else:

```
overall: PASS
posture: UNGATED (merge gate unavailable on this plan: wielas/JobApp)
```

This is ADR-0003 applied to the evidence artifact rather than to a skill body. A
bare `overall: PASS` beside an unreadable gate is exactly the claim that rule
forbids, and the relaxation in D17.4 is only honest with this line present.
`commission/every-report-states-its-posture` fails if it ever vanishes.

The recorded `exit:` for a tolerated prerequisite stays the **real** one. A 5 is
written as 5; it is not laundered into 0.

## What is actually lost, and what is not

**Lost.** Nothing server-side stops a human merging a red PR, and nothing stops a
direct push to `main`. The lefthook `no-main-push` guard is advisory by
construction — `--no-verify` and `LEFTHOOK=0` skip it — and its own comment
already says so: *"The gate that holds is off the host."* On these products
there is no such gate.

**Not lost.** GitHub Actions still run on private free-plan repositories, and
`scripts/prejudge.sh` waits on `statusCheckRollup`, which does not depend on
protection. Tier 1 is unaffected: a red PR is still detected and still bounced.
What changes is that nothing *enforces* the result at merge time.

## Frozen acceptance is not amended

`tests/features/chunk_9.feature` needs no change, and this was checked rather
than assumed. Its scenario reads *"refuses regardless of repository visibility
labels"* — a rule against using `private: true` as evidence that a gate exists.
The new verdict turns on GitHub's own capability answer, not on the label, and
its fixture (`commission/requires-enforceable-gate`) drives the **404** path,
which is untouched. Recorded explicitly because ADR-0014 D14.3 forbids
self-amendment of frozen acceptance inside an implementation PR, and a future
reader must be able to see the question was asked.

## Consequences

- `make commission` succeeds against a private free-plan product, and its report
  says in plain text that the product is ungated.
- `make preflight` gains a fifth outcome in section 10: a named WARN, distinct
  from the generic "could not run" WARN. It is dormant for `wielas/forge`, which
  is public and gated.
- `make verify SUITES=gate` is **22 cases**, `commission` is **11**. Every case
  added here was mutation-tested — defect reintroduced, suite re-run, the named
  case confirmed red, tree restored. Two of them were rewritten as a result:
  they passed with their own defect back in place, because a public repo's
  incoherent 403 was refused by the *other* mechanism's arm and the exit code
  alone could not tell which branch had decided.
- **This is fixture proof.** The live probe above confirms `merge-gate.sh`
  returns 5 for a real private repository and still returns 0 for a real gated
  public one, but no genuine `make commission` has yet run against a private
  product. Until it has, the end-to-end claim is unproven — see `docs/state.md`.
