#!/usr/bin/env bash
# Derive a verdict from the scores and findings a scorer emitted.
#
# `rubrics/judge-rubric.md` states the verdict logic as four prose rules, and
# has since the rubric was written. Nothing computed them: the model was asked
# for `verdict` alongside the scores, and whatever word came back was stored,
# routed on, and counted. A verdict that does not follow from its own scores is
# undetectable in that arrangement — which is F29.
#
# This file is the rules as a program. It decides nothing new; it is the same
# four lines of `judge-rubric.md` §"Verdict logic", executable:
#
#   any dimension == 0                           -> bounce
#   dims 1-3 all >= 2  AND  no dimension == 1    -> approve
#   every finding on a 1-scored dimension is nit -> approve-with-nits
#   else                                         -> bounce
#
# "none = 1" in rule 2 reads across all six dimensions, not across 1-3: dims 1-3
# being >= 2 already excludes a 1 among them, so the clause would be redundant
# otherwise.
#
# INVALID INPUT IS NOT A VERDICT. `judge-verdict.schema.json` says "a score
# below 3 with no corresponding finding is invalid", but says it in a
# `description`, where no validator reads it. Without the check below, rule 3
# is vacuously true for a dimension scored 1 that named no finding at all --
# `all` over an empty list is true -- so the least evidenced verdict possible
# would derive to `approve-with-nits`. Those exit non-zero instead.
#
# Usage:
#   verdict.sh <file.json>     derive from a file
#   verdict.sh < file.json     derive from stdin
#   source verdict.sh; derive_verdict "$json"
#
# Exit: 0 verdict on stdout · 2 malformed scores · 3 a score below 3 with no
# finding naming that dimension.
#
# NO TOP-LEVEL `set`. This file is sourced by prejudge-review.sh, which runs
# `set -uo pipefail` and deliberately NOT `-e`: ADR-0010 gives that script its
# own exit-code contract (0 routed, 2 usage, 3 substrate, 1 unused precisely so
# a caller under errexit cannot read a bounce as a crash), and it handles
# non-zero returns itself throughout. A sourced file that turned errexit on
# would silently rewrite the control flow of everything after the source line —
# and because the shadow stage runs only after a real model call, no --dry-run
# case would ever reach it. Shell options belong to the caller; the options for
# standalone use are set in the execution branch at the bottom instead.

derive_verdict() {
  printf '%s' "$1" | jq -er '
    def DIMS: ["spec_fidelity","scenario_integrity","architectural_conformance",
               "scope_discipline","debt_honesty","doc_reconciliation"];
    def D13:  ["spec_fidelity","scenario_integrity","architectural_conformance"];

    (.scores // {})   as $s
  | (.findings // []) as $f
  | (DIMS | map($s[.])) as $vals

  | if ($vals | any(type != "number"))
    then "verdict: scores are missing or non-numeric — not a scored review"
         | halt_error(2)
    else . end

  # A dimension marked down must say where. Schema prose, made executable.
  # Every `.` below is bound explicitly: inside select(), a bare `.dimension`
  # in index(.dimension) resolves against the array being indexed, not against
  # the finding, and silently yields null.
  | ([$f[] | .dimension]) as $named
  | ([DIMS[] | . as $d
             | select(($s[$d]) < 3)
             | select(($named | index($d)) == null)]) as $silent
  | if ($silent | length) > 0
    then "verdict: scored below 3 with no finding naming it: " + ($silent | join(", "))
         | halt_error(3)
    else . end

  | if   ($vals | any(. == 0))                                        then "bounce"
    elif ((D13 | map($s[.]) | all(. >= 2)) and ($vals | all(. != 1))) then "approve"
    else
      ([DIMS[] | . as $d | select(($s[$d]) == 1)]) as $ones
    | ([$f[] | . as $x
             | select(($ones | index($x.dimension)) != null)
             | $x.severity]) as $sev
    | if ($sev | length) > 0 and ($sev | all(. == "nit"))
      then "approve-with-nits" else "bounce" end
    end
  '
}

# Add the shadow fields to a verdict envelope. Separate from derive_verdict so
# the stamping is unit-testable without a model: the caller in
# prejudge-review.sh is one line, and every branch below is exercised by
# `make verify prejudge`.
#
# THE STAMP IS UNCONDITIONAL, AND THAT IS LOAD-BEARING. The model-facing schema
# is `judge-verdict.schema.json` minus the `STAMPED` list, and that list lives
# inside the pinned control arm, which may not be edited until ADR-0009 D9.5's
# experiment concludes. So for as long as shadow mode runs, the scorer IS shown
# these three fields and may invent values for them — the one thing
# `judge-rubric.md` says never to allow. Assigning unconditionally is what
# makes that harmless: whatever the model emits is overwritten before anything
# reads it. Adding the three to `STAMPED` belongs with the `verdict` exclusion,
# in the same slice that unpins the arm.
stamp_shadow() {
  local json="$1" derived err
  err="$(mktemp)"
  if derived="$(derive_verdict "$json" 2>"$err")"; then
    printf '%s' "$json" | jq -c --arg d "$derived" '
        .derived_verdict    = $d
      | .verdict_divergence = (.verdict != $d)
      | del(.verdict_derivation_error)'
  else
    printf '%s' "$json" | jq -c --arg e "$(head -1 "$err")" '
        .derived_verdict          = null
      | .verdict_divergence       = null
      | .verdict_derivation_error = (if $e == "" then "derivation produced no value" else $e end)'
  fi
  rm -f "$err"
}

# Only run when executed, so `source`ing this file just defines the functions
# and leaves the caller's shell options exactly as it found them.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  if [ $# -ge 1 ]; then derive_verdict "$(cat "$1")"; else derive_verdict "$(cat)"; fi
fi
