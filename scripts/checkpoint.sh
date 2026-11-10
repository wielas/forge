#!/usr/bin/env bash
# =============================================================================
# forge checkpoint — the milestone checkpoint (epic MS4, S8), as a program.
#
# Run on a milestone's GATE card once every chunk of the milestone is merged.
# It assembles the checkpoint report and decides one of three outcomes, and a
# model contributes nothing to either: every number in the report is read from a
# script, and the outcome is a fixed table over those numbers. The overseer
# (S8c) only phrases and judges what this prints (Principles: numbers come from
# scripts, never from a model).
#
# Where each number comes from, and the report tags every line with it:
#   [probe-run.sh]  the probe's verdict and its result line: scripts/probe-run.sh
#   [metrics.sh]    the milestone's chunks against the architect's estimate:
#                   scripts/metrics.sh <board> --json, its `milestones` rows
#   [gate card]     delivered requirements against the card's `Delivers:` list,
#                   the follow-ups waiting in triage, and the next milestone,
#                   read from a snapshot copy of the board (never mode=ro: a
#                   Hermes board is WAL, scripts/board-snapshot.sh)
#
# OUTCOMES, in this precedence (docs/epic-hands-free.md, decision 6 and MS4):
#   pass        the probe exits 0 AND the milestone's chunks are within the
#               gate's estimate. The milestone proceeds on its own: with --apply
#               the gate is completed and the next milestone's chunks become
#               ready. The owner decided on 2026-11-05 that a passing probe
#               auto-passes, rather than waiting for an explicit `accept`.
#   block       exit 1. A decision-first message (GW1) that waits for `accept`,
#               `redirect <text>` or `park`: the probe found a failing case; or
#               the milestone took more chunks than the estimate; or the gate
#               card has no usable estimate, so cost cannot be shown to be
#               within it. A finding that is neither clearly a product defect nor
#               a probe defect blocks with no draft offered.
#   no verdict  exit 2, never a pass: the probe could not run (its exit 2), the
#               milestone is not finished (a chunk of it is not done), or the
#               board, the gate card or the metrics could not be read.
#
# THE ABSENT ESTIMATE is a block, not a pass. A card made before PL2, or one
# whose Estimate is not "<n> chunks", gives cost nothing to be compared with,
# and a hands-free pass that skips what it cannot measure is the failure this
# epic exists to remove. The owner's auto-pass is for a milestone that was
# measured and held; it is not a licence to pass one that was not.
#
# FINDINGS ARE CLASSIFIED, case by case, from evidence the runner prints and the
# frozen probe holds. A hang, a crash with a traceback, or an adversarial input
# the product accepted is a PRODUCT defect: a chunk-card DRAFT. An expectation
# the product's output meets except for letter case or spacing is a PROBE
# defect: an amendment DRAFT. Anything else — a usage error, a wrong exit, a
# stdout miss — is AMBIGUOUS and gets no draft: the operator classifies it.
# Drafts are text. Nothing is created on the board.
#
# THE MODES, one of which is required, so a run can never release by default:
#   --rehearse  writes nothing. Not to the board, not to GitHub. The report ends
#               with what --apply WOULD have done. This is the only mode a held
#               gate may be rehearsed with; --apply is refused beside it.
#   --apply     the one write there is: on a pass, `complete` on the gate card.
#               `complete` exiting 0 is not enough: the gate is read again from a
#               fresh snapshot and must read `done`, or this exits 2 and says the
#               gate did NOT pass.
#               On a block the gate is already held by the bootstrap, and
#               blocking it again would trip the kernel's recurrence limit into
#               `triage`, so a block writes nothing and only prints the message.
#               The card must be `blocked` (held), or it is refused.
# Every board write passes through board_write(), the only place the mode is
# honoured. `make verify` (checkpoint/rehearse-writes-nothing) runs every outcome
# in --rehearse against a hermes stub that fails on any write verb.
#
# Usage:
#   ./scripts/checkpoint.sh <project-dir> --board <slug> --gate GATE-<m> --rehearse [--timeout <seconds>]
#   ./scripts/checkpoint.sh <project-dir> --board <slug> --gate GATE-<m> --apply [--timeout <seconds>]
#
# Exit: 0 pass (proceeds), 1 block (waiting on a decision), 2 no verdict or the
#       checkpoint could not be run.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# Exit:/{exit} u' "$0"; }

_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "checkpoint: script directory cannot be resolved" >&2; exit 2; }
# shellcheck source=decision-message.sh
. "$HERE/decision-message.sh" || { echo "checkpoint: cannot source decision-message.sh" >&2; exit 2; }

PROJECT=""; BOARD=""; GATE=""; MODE=""; TIMEOUT=600
while [ $# -gt 0 ]; do
  case "$1" in
    --board) [ $# -ge 2 ] || { echo "checkpoint: --board needs a slug" >&2; exit 2; }; BOARD="$2"; shift 2;;
    --gate)  [ $# -ge 2 ] || { echo "checkpoint: --gate needs GATE-<milestone>" >&2; exit 2; }; GATE="$2"; shift 2;;
    --timeout) [ $# -ge 2 ] || { echo "checkpoint: --timeout needs a number of seconds" >&2; exit 2; }; TIMEOUT="$2"; shift 2;;
    --rehearse)
      [ "$MODE" != apply ] || { echo "checkpoint: --rehearse and --apply are exclusive; a rehearsal releases nothing" >&2; exit 2; }
      MODE=rehearse; shift;;
    --apply)
      [ "$MODE" != rehearse ] || { echo "checkpoint: --rehearse and --apply are exclusive; a rehearsal releases nothing" >&2; exit 2; }
      MODE=apply; shift;;
    -h|--help) helptext; exit 0;;
    -*) echo "checkpoint: unknown argument: $1" >&2; exit 2;;
    *) if [ -z "$PROJECT" ]; then PROJECT="$1"
       else echo "checkpoint: unexpected argument: $1" >&2; exit 2
       fi
       shift;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$BOARD" ] && [ -n "$GATE" ] || { usagetext >&2; exit 2; }
[ -n "$MODE" ] || { echo "checkpoint: say --rehearse (writes nothing) or --apply (completes the gate on a pass)" >&2; exit 2; }
[ -d "$PROJECT" ] || { echo "checkpoint: no such project directory: $PROJECT" >&2; exit 2; }
gate_re='^GATE-[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $GATE =~ $gate_re ]] || { echo "checkpoint: '$GATE' is not a gate id (GATE-<milestone>)" >&2; exit 2; }
board_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $BOARD =~ $board_re ]] || { echo "checkpoint: '$BOARD' is not a board slug" >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "checkpoint: --timeout must be 1 to 86400 seconds, not '$TIMEOUT'" >&2; exit 2;; esac
if [ "$TIMEOUT" -lt 1 ] || [ "$TIMEOUT" -gt 86400 ]; then
  echo "checkpoint: --timeout must be 1 to 86400 seconds, not '$TIMEOUT'" >&2; exit 2
fi
for tool in sqlite3 jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "checkpoint: $tool is not on PATH" >&2; exit 2; }
done
PROJECT="$(cd "$PROJECT" && pwd -P)"

# ---------------------------------------------------------------------------
# The board, read from a snapshot copy. Resolved as metrics.sh resolves it.
# ---------------------------------------------------------------------------
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
KANBAN_ROOT="${HERMES_KANBAN_HOME:-$HERMES_ROOT/kanban}"
if [ "$BOARD" = "default" ]; then DB="$HERMES_ROOT/kanban.db"
else DB="$KANBAN_ROOT/boards/$BOARD/kanban.db"; fi
[ -f "$DB" ] || { echo "checkpoint: no board database at $DB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-checkpoint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SNAP="$("$HERE/board-snapshot.sh" "$DB" "$WORK/board")" || {
  echo "checkpoint: could not snapshot board $BOARD; refusing to report numbers from a board that was not read" >&2
  exit 2; }
[ -n "$SNAP" ] || { echo "checkpoint: snapshot of board $BOARD returned no path" >&2; exit 2; }

# The only way this script changes a board. The mode is honoured here and
# nowhere else, so a new write path cannot be added that forgets it (the bug
# class of epic P10(1): a --dry-run that made its transition before the check).
board_write() { # $@ = the hermes kanban arguments after --board <slug>
  if [ "$MODE" != apply ]; then
    echo "would run: hermes kanban --board $BOARD $*   (rehearsal: not run)"
    return 0
  fi
  hermes kanban --board "$BOARD" "$@"
}

# no_verdict <reason> — nothing is decided; exit 2.
no_verdict() {
  printf 'checkpoint %s — %s\n' "$GATE" "$MODE"
  printf 'NO VERDICT: %s\n' "$1"
  [ "$MODE" = rehearse ] && echo "rehearsal: nothing was written to the board"
  exit 2
}

# ---- the gate card ---------------------------------------------------------
gate_q="SELECT json_object('card', id, 'title', title, 'status', status, 'body', body)
          FROM tasks WHERE substr(title, 1, length('$GATE') + 1) = '$GATE:'
                        OR title = '$GATE';"
GATE_ROWS="$(sqlite3 "$SNAP" "$gate_q" 2>/dev/null)" || no_verdict "the board snapshot could not be queried for $GATE"
case "$(printf '%s\n' "$GATE_ROWS" | grep -c .)" in
  1) ;;
  0) no_verdict "board $BOARD has no card for $GATE";;
  *) no_verdict "board $BOARD has more than one card for $GATE";;
esac
GCARD="$(printf '%s' "$GATE_ROWS" | jq -r '.card')"
GSTATUS="$(printf '%s' "$GATE_ROWS" | jq -r '.status')"
if [ "$MODE" = apply ] && [ "$GSTATUS" != blocked ]; then
  no_verdict "$GATE ($GCARD) is $GSTATUS, not blocked (held); --apply completes only a held gate"
fi

PARENTS="$(sqlite3 "$SNAP" "SELECT COALESCE(json_group_array(json_object('card', p.id, 'title', p.title,
              'status', p.status, 'body', p.body)), json_array())
            FROM (SELECT t.* FROM tasks t JOIN task_links l ON l.parent_id = t.id
                   WHERE l.child_id = '$GCARD' AND t.status <> 'archived' ORDER BY t.title) p;" 2>/dev/null)" \
  || no_verdict "the gate's chunks could not be read"
CHILDREN="$(sqlite3 "$SNAP" "SELECT COALESCE(json_group_array(json_object('card', c.id, 'title', c.title,
              'status', c.status, 'body', c.body)), json_array())
            FROM (SELECT t.* FROM tasks t JOIN task_links l ON l.child_id = t.id
                   WHERE l.parent_id = '$GCARD' AND t.status <> 'archived' ORDER BY t.title) c;" 2>/dev/null)" \
  || no_verdict "the next milestone's chunks could not be read"
FOLLOWUPS="$(sqlite3 "$SNAP" "SELECT COALESCE(json_group_array(json_object('card', id, 'title', title)), json_array())
            FROM (SELECT id, title FROM tasks WHERE status = 'triage' ORDER BY created_at, id);" 2>/dev/null)" \
  || no_verdict "the follow-ups in triage could not be read"
CHUNK_TITLES="$(sqlite3 "$SNAP" "SELECT COALESCE(json_group_array(title), json_array()) FROM tasks
                                  WHERE title LIKE 'CHUNK-%';" 2>/dev/null)" || CHUNK_TITLES='[]'
NEXT_N="$(printf '%s' "$CHUNK_TITLES" | jq -r '[.[] | capture("^CHUNK-(?<n>[0-9]+)") | .n | tonumber] | (max // 0) + 1')"

# ---- delivered against the requirements the card names ---------------------
# `Delivers:` ends its first sentence at ". " — the Squatfather's M1 goes on to
# "It also lays the offline rules that FR-1 ... finish in M2 or M3", which are
# laid, not delivered. A requirement is delivered when at least one chunk serves
# it and every chunk that serves it is done; `Serves:` stops at the "·" that
# separates it from `Relevant ADRs:` on the same line.
FRS="$(jq -n --argjson g "$GATE_ROWS" --argjson parents "$PARENTS" '
  def field($body; $name): (($body // "") | split("\n")
      | map(select(test("^[-* \\t]*\\*\\*" + $name + ":\\*\\*"))) | .[0]
      | if . == null then null
        else sub("^[-* \\t]*\\*\\*" + $name + ":\\*\\*[ \\t]*"; "") | sub("[ \\t\\r]+$"; "") end);
  def toks: [scan("\\b(?:N?FR)-[0-9]+\\b")] | unique;
  (field($g.body; "Delivers")) as $del
  | (if $del == null then [] else ($del | split(". ")[0] | toks) end) as $named
  | (if $del == null then [] else (($del | split(". ")[1:] | join(". ") | toks) - $named) end) as $laid
  | [$named[] | . as $fr
      | ([$parents[] | select(((field(.body; "Serves") // "") | split("·")[0] | toks) | index($fr))]) as $srv
      | { fr: $fr,
          servers: [$srv[] | (.title | split(":")[0])],
          state: (if ($srv | length) == 0 then "unserved"
                  elif ([$srv[] | select(.status != "done")] | length) == 0 then "delivered"
                  else "pending" end) }] as $rows
  | { named: $named, laid_for_later: $laid, rows: $rows,
      delivered: [$rows[] | select(.state == "delivered") | .fr],
      pending: [$rows[] | select(.state == "pending") | .fr],
      unserved: [$rows[] | select(.state == "unserved") | .fr],
      has_delivers: ($del != null) }')" || no_verdict "the gate card's Delivers list could not be read"

# ---- the next milestone ----------------------------------------------------
NEXT="$(jq -n --argjson children "$CHILDREN" '
  { chunks: ($children | length),
    milestones: ([$children[] | (.body // "" | capture("\\*\\*Milestone:\\*\\*[ \\t]*(?<m>M[0-9]+)")? | .m)] | map(select(. != null)) | unique),
    titles: [$children[] | .title] }')"

# ---- cost against the estimate: metrics.sh ---------------------------------
METRICS="$("$HERE/metrics.sh" "$BOARD" --json 2>"$WORK/metrics.err")" \
  || no_verdict "metrics.sh could not read board $BOARD, so cost against the estimate is unmeasured ($(tail -n 1 "$WORK/metrics.err"))"
COST="$(printf '%s' "$METRICS" | jq -c --arg card "$GCARD" '[.milestones[]? | select(.card == $card)] | .[0] // empty')"
[ -n "$COST" ] || no_verdict "metrics.sh reported no milestone row for $GATE ($GCARD)"
ACTUAL="$(printf '%s' "$COST" | jq -r '.actual')"
DONE="$(printf '%s' "$COST" | jq -r '.done')"
EST_STATUS="$(printf '%s' "$COST" | jq -r '.estimate_status')"
EST="$(printf '%s' "$COST" | jq -r '.estimate // empty')"
OVER="$(printf '%s' "$COST" | jq -r 'if .over == null then "" else (.over | tostring) end')"   # not // empty: false is a value

# metrics.sh reads the board through its own snapshot, and this script through
# another, so a board that moved between the two reads would otherwise be
# judged on two different boards. The gate's chunks are counted here too, from
# this script's snapshot, and any disagreement is no verdict, never a pass.
P_TOTAL="$(printf '%s' "$PARENTS" | jq -r 'length')"
P_DONE="$(printf '%s' "$PARENTS" | jq -r '[.[] | select(.status == "done")] | length')"
if [ "$ACTUAL" != "$P_TOTAL" ] || [ "$DONE" != "$P_DONE" ]; then no_verdict "metrics.sh counts $DONE of $ACTUAL chunk(s) done but this checkpoint's own read of the board counts $P_DONE of $P_TOTAL, so the two reads saw different boards; run it again once the board is quiet"; fi # consistency-check

# ---- the probe: probe-run.sh -----------------------------------------------
# Run only for a finished milestone. A probe over unmerged work says nothing
# about the milestone, so an unfinished one has no verdict.
PROBE_RC=""; PROBE_LAST=""
NOT_DONE="$(printf '%s' "$PARENTS" | jq -r '[.[] | select(.status != "done") | "\(.title | split(":")[0]) is \(.status)"] | join("; ")')"
: >"$WORK/probe.out"
if [ "$ACTUAL" -gt 0 ] 2>/dev/null && [ "$DONE" = "$ACTUAL" ] && [ -z "$NOT_DONE" ]; then
  "$HERE/probe-run.sh" "$PROJECT" "$GATE" --timeout "$TIMEOUT" >"$WORK/probe.out" 2>"$WORK/probe.err"
  PROBE_RC=$?
  PROBE_LAST="$(tail -n 1 "$WORK/probe.out" 2>/dev/null)"
  case "$PROBE_RC" in 0|1) ;; *) PROBE_RC=2;; esac   # anything else is no verdict, never a pass
  if [ "$PROBE_RC" = 2 ] && ! printf '%s' "$PROBE_LAST" | grep -q 'NO VERDICT'; then
    PROBE_LAST="probe $GATE: NO VERDICT — $(tail -n 1 "$WORK/probe.err" 2>/dev/null)"
  fi
fi

# ---- classify a finding ----------------------------------------------------
CLASSIFIED='{"class":"none","cases":[],"drafts":[]}'
if [ "$PROBE_RC" = 1 ]; then
  CLASSIFIED="$(python3 - "$HERE" "$PROJECT" "$GATE" "$NEXT_N" "$WORK/probe.out" <<'PY'
import json
import re
import sys

here, project, gate, next_n, out_path = sys.argv[1:6]
sys.dont_write_bytecode = True
sys.path.insert(0, here)
from pathlib import Path
from forge_probe import probe_path, validate_probe

probe, _, error = validate_probe(Path(project), gate)
frozen = {c["name"]: c for c in probe["cases"]} if not error else {}
rel = probe_path(gate)

lines = open(out_path, encoding="utf-8", errors="replace").read().splitlines()
fail_re = re.compile(r"^FAIL  (.*) \((realistic|adversarial)(?:, \d+ records)?\) — (.*)$")
cases = []
for i, line in enumerate(lines):
    m = fail_re.match(line)
    if not m:
        continue
    name, kind, misses = m.groups()
    shown = []
    for after in lines[i + 1:]:
        if not after.startswith("      "):
            break
        shown.append(after.strip())
    cases.append({"name": name, "kind": kind, "misses": misses, "shown": shown})


def norm(text):
    return " ".join(text.casefold().split())


def judge(case):
    misses, shown = case["misses"], case["shown"]
    text = "\n".join(shown)
    spec = frozen.get(case["name"])
    exit_miss = re.search(r"exit (\d+), expected (\d+)", misses)
    if misses.startswith("timed out"):
        return "product", "it ran past the timeout on this input: a hang or a loop"
    if "Traceback (most recent call last)" in text:
        return "product", "it crashed with a traceback on this input"
    if (case["kind"] == "adversarial" and exit_miss
            and exit_miss.group(1) == "0" and exit_miss.group(2) != "0"):
        return "product", "it accepted an input the probe says it must reject (fails open)"
    if not exit_miss and spec and "stdout" in spec["expect"]:
        want = norm(spec["expect"]["stdout"])
        for row in shown:
            body = row[2:] if row.startswith("| ") else row
            # the whole expected text, bounded: "advance 3" is not found in "Advance 30"
            if want and re.search(r"(?<![a-z0-9])" + re.escape(want) + r"(?![a-z0-9])", norm(body)):
                return ("probe", "the product printed the expected text with different case or spacing "
                        f"({body!r}); the expectation is over-literal", body)
    if "usage:" in text.lower() and exit_miss and exit_miss.group(1) == "2":
        return "ambiguous", "a usage error: the product's interface and the probe's argv disagree, and either could be wrong"
    return "ambiguous", "the evidence fits both a product defect and a probe defect"


drafts = []
for case in cases:
    verdict = judge(case)
    case["class"], case["reason"] = verdict[0], verdict[1]
    spec = frozen.get(case["name"])
    if spec:
        exp = spec["expect"]
        then = f"it exits {exp['exit']}" + (f" and prints {exp['stdout']!r}" if "stdout" in exp else "")
        run = " ".join(spec["run"])
        given = f"the {spec['kind']} input {spec['input']}"
        if case["class"] == "product":
            drafts.append({"kind": "chunk-card", "case": case["name"], "text": "\n".join([
                "DRAFT chunk card — not created; nothing was written to the board:",
                f"### CHUNK-{next_n}: Make {gate}'s probe case hold: {case['name']}",
                f"- **Goal:** Make the probe case \"{case['name']}\" hold. The probe found: {case['reason']}.",
                f"- **Milestone:** {gate.removeprefix('GATE-')}  ·  **Depends on:** none",
                "- **Serves:** <the requirement this case guards>",
                "- **Scenarios:**",
                f"  - Given {given}, When `{run}` runs from the project root, Then {then}.",
                "- **Real sources:** none",
                f"- **Acceptance:** tests/features/chunk_{next_n}.feature",
                f"- **Out of scope:** changing {rel}; any other case's behaviour.",
                f"- **Done when:** `make check` green + the scenario passes + {gate}'s probe passes.",
                "- **Lane:** forge-codex-lane  ·  **Risk:** med"])})
        elif case["class"] == "probe":
            proposed = verdict[2] if len(verdict) > 2 else ""
            drafts.append({"kind": "amendment", "case": case["name"], "text": "\n".join([
                f"DRAFT amendment to {rel} — not applied:",
                f"- case: \"{case['name']}\" ({case['kind']})",
                f"- expects today: {then}",
                f"- finding: {case['reason']}",
                f"- proposed: expect stdout {proposed!r} instead",
                "- to apply: ~/.forge/repo/scripts/amend-contract.sh <project> --id " + gate + " --set " + rel + "=<edited probe> --reason <why> --rehearse,",
                "  then --apply. It re-freezes through acceptance-freeze and records the decision entry, or changes nothing.",
                "  A probe is a frozen plan, so this is a contract amendment."])})

classes = sorted({c["class"] for c in cases})
if not cases:
    overall = "ambiguous"  # a finding the runner named but this could not read: never guess
elif classes == ["product"]:
    overall = "product"
elif classes == ["probe"]:
    overall = "probe"
elif "ambiguous" in classes:
    overall = "ambiguous"
else:
    overall = "mixed"
if overall == "ambiguous":
    drafts = []
print(json.dumps({"class": overall, "cases": cases, "drafts": drafts}))
PY
)" || CLASSIFIED='{"class":"ambiguous","cases":[],"drafts":[]}'
fi

# ---- the outcome -----------------------------------------------------------
# One row per reason it cannot pass, most important first. A pass has none.
REASONS=""
add_reason() { REASONS="$REASONS $1"; }
if [ "$PROBE_RC" = 1 ]; then
  case "$(printf '%s' "$CLASSIFIED" | jq -r '.class')" in
    ambiguous) add_reason finding-ambiguous;;
    *) add_reason finding;;
  esac
fi
case "$EST_STATUS" in
  ok) case "$OVER" in
        false) ;;
        true) add_reason cost-over;;
        *) add_reason cost-unmeasured;;   # an estimate with no comparison is unmeasured
      esac;;
  *) add_reason cost-unmeasured;;
esac
REASONS="${REASONS# }"
FIRST="${REASONS%% *}"

# Fail closed: no verdict is the default, and a pass is set in exactly one
# place, by a probe that exited 0 with nothing else blocking. A probe that never
# ran, or whose exit is anything but 0 or 1, stays no verdict.
OUTCOME=no-verdict
if [ -n "$NOT_DONE" ] || [ "$ACTUAL" = 0 ]; then OUTCOME=no-verdict
elif [ "$PROBE_RC" = 0 ] && [ -z "$REASONS" ]; then OUTCOME=pass
elif [ "$PROBE_RC" = 0 ] || [ "$PROBE_RC" = 1 ]; then OUTCOME=block
fi

# ---- the report ------------------------------------------------------------
if [ "$MODE" = rehearse ]; then
  mode_line="REHEARSAL — releases nothing; board and GitHub are not written"
else
  mode_line="APPLY — completes the gate on a pass"
fi

say_numbers() {
  echo "Numbers (each read from a script; the tag names which):"
  printf '  [gate card]     %s (%s) is %s on board %s\n' "$GATE" "$GCARD" "$GSTATUS" "$BOARD"
  if [ -n "$PROBE_RC" ]; then
    printf '  [probe-run.sh]  exit %s — %s\n' "$PROBE_RC" "$PROBE_LAST"
  else
    printf '  [probe-run.sh]  not run\n'
  fi
  printf '  [metrics.sh]    %s of %s chunk(s) done\n' "$DONE" "$ACTUAL"
  case "$EST_STATUS" in
    ok) printf '  [metrics.sh]    cost: %s chunk(s) against an estimate of %s chunk(s)%s\n' \
          "$ACTUAL" "$EST" "$([ "$OVER" = true ] && echo ' — OVER')";;
    absent) printf '  [metrics.sh]    cost: %s chunk(s) against NO estimate (the card has no Estimate line) — unmeasured\n' "$ACTUAL";;
    *) printf "  [metrics.sh]    cost: %s chunk(s) against an estimate that is not '<n> chunks' (%s) — unmeasured\n" \
         "$ACTUAL" "$(printf '%s' "$COST" | jq -r '.estimate_raw')";;
  esac
  printf '  [gate card]     requirements delivered: %s of %s named in Delivers' \
    "$(printf '%s' "$FRS" | jq -r '.delivered | length')" "$(printf '%s' "$FRS" | jq -r '.named | length')"
  if [ "$(printf '%s' "$FRS" | jq -r '.has_delivers')" != true ]; then printf ' (the card has no Delivers line)'; fi
  echo
  printf '%s' "$FRS" | jq -r '
    (if (.delivered | length) > 0 then "                  delivered: " + (.delivered | join(", ")) else empty end),
    (if (.pending | length) > 0 then "                  not yet: " + (.pending | join(", ")) + " (a chunk serving it is not done)" else empty end),
    (if (.unserved | length) > 0 then "                  unserved: " + (.unserved | join(", ")) + " (no chunk of this milestone serves it)" else empty end),
    (if (.laid_for_later | length) > 0 then "                  laid for later milestones: " + (.laid_for_later | join(", ")) else empty end)'
  printf '  [gate card]     follow-ups waiting in triage: %s\n' "$(printf '%s' "$FOLLOWUPS" | jq -r 'length')"
  printf '%s' "$FOLLOWUPS" | jq -r '.[] | "                  \(.card)  \(.title)"'
  printf '%s' "$NEXT" | jq -r '
    "  [gate card]     next milestone: " + (if .chunks == 0 then "none — no chunk waits on this gate"
       else ((if (.milestones | length) > 0 then (.milestones | join(", ")) else "unnamed" end)
             + ", " + (.chunks | tostring) + " chunk(s) held until the gate is done") end)'
  if [ "$PROBE_RC" = 1 ]; then
    echo "  findings, classified by the checkpoint:"
    printf '%s' "$CLASSIFIED" | jq -r '.cases[] | "    \(.class | ascii_upcase)  \(.name) — \(.reason)"'
  fi
}

# read_gate_back: read the gate card's status from a fresh snapshot into DONE_STATUS. Succeeds only when the
# board was actually read (a gate that is gone reads as the empty string, which is a read); two tries, because a
# snapshot is a copy of a board that Hermes may be writing. Fails when neither try read the board.
read_gate_back() {
  local try snap
  for try in 1 2; do
    snap="$("$HERE/board-snapshot.sh" "$DB" "$WORK/board-after$try" 2>/dev/null)" && [ -n "$snap" ] || continue
    DONE_STATUS="$(sqlite3 "$snap" "SELECT status FROM tasks WHERE id = '$GCARD';" 2>/dev/null)" && return 0
  done
  return 1
}

reply_text() {
  printf '%s' "\`accept\` completes the gate as it is: \`hermes kanban --board $BOARD complete $GCARD --result \"accepted: <why>\"\`; \`redirect <text>\` says what to change, and the run waits; \`park\` leaves the gate held and the run stopped. Today only \`accept\` has a command; the others are decisions you make by editing the plan or doing nothing."
}

printf 'checkpoint %s — %s\n\n' "$GATE" "$mode_line"
case "$OUTCOME" in
  pass)
    # "passes" is said only once the gate is really complete. It used to be printed first, so a
    # `complete` the kernel refused still left "passes" in the log and in the operator's notification
    # (#102 minor a). In a rehearsal nothing is completed, so the line is the verdict on the numbers.
    COMPLETE_OUT=""
    if [ "$MODE" = apply ]; then
      # (#102 minor b) The gate was read at the top of this run, before the probe, which can take
      # minutes. Read it again immediately before writing: a gate that is no longer held (completed
      # by hand, reopened, archived) is no verdict, and nothing is completed over it.
      NOW_SNAP="$("$HERE/board-snapshot.sh" "$DB" "$WORK/board-recheck")" && [ -n "$NOW_SNAP" ] \
        || no_verdict "$GATE ($GCARD) could not be read again just before completing it, so nothing was completed"
      NOW_STATUS="$(sqlite3 "$NOW_SNAP" "SELECT status FROM tasks WHERE id = '$GCARD';" 2>/dev/null)" # gate-reread
      [ "$NOW_STATUS" = blocked ] || no_verdict "$GATE ($GCARD) moved while the checkpoint ran: it is now '${NOW_STATUS:-gone}', not blocked (held); nothing was completed" # gate-reread
      COMPLETE_OUT="$(board_write complete "$GCARD" --result "checkpoint pass: $PROBE_LAST" 2>&1)"; COMPLETE_RC=$?
      [ "$COMPLETE_RC" = 0 ] || { echo "checkpoint: completing $GCARD failed — $GATE did NOT pass and the gate is still held: $COMPLETE_OUT" >&2; exit 2; } # complete-checked
      # (#105 review, finding 5) A zero exit is the kernel's word; the board is the evidence. Read the gate
      # once more, from a fresh snapshot (a copy, never mode=ro: a Hermes board is WAL), and say "passes"
      # only if it reads done. A read that itself fails is not "the gate is not done": it is unknown, so it is
      # tried once more and, if it still fails, reported as unverified, with no pass and no success line.
      DONE_STATUS=""
      read_gate_back || { echo "checkpoint: completing $GCARD reported success, but the board could not be read back (tried twice), so completion is unverified — check the card $GCARD: it may or may not be done, and no pass is recorded" >&2; exit 2; } # complete-unverified
      [ "$DONE_STATUS" = done ] || { echo "checkpoint: completing $GCARD reported success, but a fresh read of the board reads the gate as '${DONE_STATUS:-gone}', not done — $GATE did NOT pass: $COMPLETE_OUT" >&2; exit 2; } # complete-readback
    fi
    echo "checkpoint: $GATE passes — the probe holds and the milestone is within its estimate, so it proceeds on its own (decision 6)"
    echo
    say_numbers
    echo
    if [ "$MODE" = rehearse ]; then
      echo "On --apply this would complete the gate, which releases the next milestone:"
      board_write complete "$GCARD" --result "checkpoint pass: $PROBE_LAST"
      echo "rehearsal: nothing was written to the board"
    else
      [ -z "$COMPLETE_OUT" ] || printf '%s\n' "$COMPLETE_OUT"
      echo "completed $GCARD"
    fi
    exit 0;;
  no-verdict)
    if [ -n "$NOT_DONE" ]; then why="the milestone is not finished: $NOT_DONE"
    elif [ "$ACTUAL" = 0 ]; then why="$GATE has no chunk cards, so there is no milestone to check"
    else why="the probe has no verdict — ${PROBE_LAST:-it did not run}"; fi
    echo "NO VERDICT: $why"
    echo
    say_numbers
    echo
    echo "Nothing passes on a missing verdict. Repair the cause and run the checkpoint again."
    [ "$MODE" = rehearse ] && echo "rehearsal: nothing was written to the board"
    exit 2;;
  block)
    case "$FIRST" in
      finding)
        names="$(printf '%s' "$CLASSIFIED" | jq -r '[.cases[].name] | join("; ")')"
        decision_message checkpoint \
          "$GATE's probe found a failing case: $names" \
          "each chunk passed review, but the milestone does not behave as planned; $(printf '%s' "$NEXT" | jq -r 'if .chunks == 0 then "nothing waits on this gate" else (.chunks | tostring) + " chunk(s) of the next milestone stay held" end')" \
          "accept the milestone as it is, redirect it, or park the run; the drafts below are ready if you redirect" \
          "accepting starts the next milestone on work the probe says is wrong" \
          "$(reply_text)";;
      finding-ambiguous)
        names="$(printf '%s' "$CLASSIFIED" | jq -r '[.cases[].name] | join("; ")')"
        decision_message checkpoint \
          "$GATE's probe found a failing case the checkpoint cannot classify: $names" \
          "the evidence fits a product defect and a probe defect alike, so no draft is offered and nothing is guessed" \
          "say whether it is a product defect or a probe defect, then accept, redirect or park" \
          "guessing wrong either ships a defect or rewrites a frozen probe" \
          "$(reply_text)";;
      cost-over)
        decision_message checkpoint \
          "$GATE took $ACTUAL chunks against an estimate of $EST" \
          "the probe holds, but the milestone cost more than the architect planned" \
          "accept the overrun, redirect the plan, or park the run" \
          "accepting lets the overrun pass unexamined into the next milestone's budget" \
          "$(reply_text)";;
      *)
        decision_message checkpoint \
          "$GATE's card has no usable estimate, so its cost cannot be compared" \
          "the probe holds, but cost against the estimate is unmeasured, and an unmeasured milestone does not pass on its own" \
          "accept without a cost check, add the estimate to the card, or park the run" \
          "accepting skips the cost check for this milestone" \
          "$(reply_text)";;
    esac
    echo
    other="$(printf '%s' "$REASONS" | tr ' ' '\n' | sed '1d' | paste -sd, - | sed 's/,/, /g')"
    if [ -n "$other" ]; then echo "Also blocking: $other"; echo; fi
    say_numbers
    if [ "$(printf '%s' "$CLASSIFIED" | jq -r '.drafts | length')" -gt 0 ]; then
      echo
      printf '%s' "$CLASSIFIED" | jq -r '.drafts[] | .text + "\n"'
    fi
    [ "$MODE" = rehearse ] && echo "rehearsal: nothing was written to the board"
    exit 1;;
esac
