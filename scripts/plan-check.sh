#!/usr/bin/env bash
# =============================================================================
# forge plan-check — what /scope and /architect promise, executed (epic PL1, PL2).
#
# ADR-0003: a claim that cannot be asserted may not appear in a skill body. The
# scope skill promises an ambition dial, a complexity budget, a delight pass, a
# gold-plating pass and a non-empty out-of-scope list. The architect skill
# promises a feasibility ledger whose spikes exist, whose rows each end in a
# keep / cut / defer / swap call, and whose kept estimate fits the scope's
# budget. Each of those is a line of a file, so each is a check here.
#
# WHY THE BUDGET IS A NUMBER. redglass planned 20 chunks and JobApp 16, and
# nothing in the plan said whether that was the size the operator wanted.
# A budget written at scope time is the one number the architect's estimate and
# the roadmap's chunk count can both be held to: the architect loops back to
# scope when the ledger does not fit it (`budget-fit` below), and
# `roadmap-check.sh`'s `budget` check reads the same number through `--facts`,
# so the parse has ONE definition and cannot drift between the two scripts.
#
# Usage:
#   ./scripts/plan-check.sh <project-dir> --stage scope       # docs/REQUIREMENTS.md
#   ./scripts/plan-check.sh <project-dir> --stage architect   # docs/feasibility.md
#   ./scripts/plan-check.sh <project-dir> --facts             # JSON for roadmap-check
#
# Exit: 0 every check passed (or --facts printed),
#       1 a finding: the planning document is incomplete — fix it before sign-off,
#       2 the check could not run: no project, no python3, or the stage's
#         document does not exist. As in roadmap-check.sh, a finding is a
#         statement about the plan and a 2 is a fact about the substrate.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }

PROJECT=""; STAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) STAGE="${2:-}"; shift 2 || { usagetext >&2; exit 2; };;
    --facts) STAGE=facts; shift;;
    -h|--help) helptext; exit 0;;
    -*) echo "plan-check: unknown argument: $1" >&2; exit 2;;
    *) [ -z "$PROJECT" ] || { echo "plan-check: only one project: got '$PROJECT' and '$1'" >&2; exit 2; }
       PROJECT="$1"; shift;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$STAGE" ] || { usagetext >&2; exit 2; }
case "$STAGE" in scope|architect|facts) ;; *)
  echo "plan-check: --stage is scope or architect, not '$STAGE'" >&2; exit 2;; esac
[ -d "$PROJECT" ] || { echo "plan-check: no such project directory: $PROJECT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "plan-check: python3 is not on PATH" >&2; exit 2; }

python3 - "$PROJECT" "$STAGE" <<'PY'
import json
import re
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
stage = sys.argv[2]
requirements_path = project / "docs" / "REQUIREMENTS.md"
ledger_path = project / "docs" / "feasibility.md"

AMBITIONS = ("toy", "tool", "product")
VERDICTS = ("proven", "disproven", "not-spiked")
TIERS = ("cheap", "strong", "local", "human")
CALLS = ("keep", "cut", "defer", "swap")
# Order matters: it is the order the architect skill names them in.
LEDGER_COLUMNS = ("component", "approach", "prior art", "spike", "verdict",
                  "chunks", "tier", "cost", "call")
KEPT = ("keep", "swap")

results = []


def emit(check, status, evidence, action=""):
    results.append((check, status, evidence, action))


def read(path):
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError) as exc:
        print(f"plan-check: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(2)


def section(text, heading):
    """Lines under the first `## <heading>...` up to the next `## `, or None."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if re.match(rf"^##\s+{re.escape(heading)}\b", line, re.IGNORECASE):
            body = []
            for nxt in lines[i + 1:]:
                if re.match(r"^#{1,2}\s", nxt):
                    break
                body.append(nxt)
            return body
    return None


def items(body):
    """Bulleted or numbered list items in a section body."""
    return [m.group(1).strip() for line in body or []
            for m in [re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(\S.*)$", line)] if m]


def field(text, name):
    """Every value of a `**Name:** value` line."""
    return [m.group(1).strip() for m in re.finditer(
        rf"(?m)^\s*(?:[-*]\s+)?\*\*{re.escape(name)}:\*\*\s*(.*?)\s*$", text)]


def budget_of(text):
    """(milestones, chunks) from the one Complexity budget line, or an error."""
    values = field(text, "Complexity budget")
    if len(values) != 1:
        return None, f"{len(values)} `**Complexity budget:**` line(s); expected exactly one"
    m = re.fullmatch(r"(\d+)\s+milestones?\s*,\s*(\d+)\s+chunks?\.?", values[0],
                     re.IGNORECASE)
    if not m:
        return None, f"`{values[0]}` is not `<n> milestones, <n> chunks`"
    milestones, chunks = int(m.group(1)), int(m.group(2))
    if milestones < 1 or chunks < 1:
        return None, f"`{values[0]}` must budget at least one milestone and one chunk"
    if milestones > chunks:
        return None, f"`{values[0]}` has more milestones than chunks; a milestone closes at least one chunk"
    return (milestones, chunks), None


def defined_frs(text):
    """FR ids that open a list item or heading under `## Functional requirements`.
    Only there: a Delight item citing FR-9 must not define FR-9 by citing it."""
    body = section(text, "Functional requirements") or []
    return set(re.findall(
        r"(?m)^\s*(?:[-*+]|\d+[.)]|#{1,6})?\s*[*`]*\s*(FR-\d+)\b", "\n".join(body)))


def ledger_rows(text):
    """(rows, error). Rows are dicts keyed by LEDGER_COLUMNS."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip().lower() for c in line.strip().strip("|").split("|")]
        if tuple(cells) != LEDGER_COLUMNS:
            continue
        rows = []
        for body in lines[i + 2:]:
            if not body.strip().startswith("|"):
                break
            values = [c.strip() for c in body.strip().strip("|").split("|")]
            if len(values) != len(LEDGER_COLUMNS):
                return None, f"ledger row `{body.strip()}` has {len(values)} cells, expected {len(LEDGER_COLUMNS)}"
            rows.append(dict(zip(LEDGER_COLUMNS, values)))
        return rows, None
    return None, ("no table whose header is exactly | "
                  + " | ".join(c.capitalize() for c in LEDGER_COLUMNS) + " |")


def plain(cell):
    return cell.replace("`", "").strip()


def kept_chunks(rows):
    total = 0
    for row in rows:
        if plain(row["call"]).lower() in KEPT and re.fullmatch(r"\d+", plain(row["chunks"])):
            total += int(plain(row["chunks"]))
    return total


# ---------------------------------------------------------------------------
# --facts: the numbers roadmap-check.sh holds a roadmap to. Absent is null,
# never zero — a plan with no budget has not been budgeted, and roadmap-check
# SKIPS on null rather than passing a comparison against nothing.
# ---------------------------------------------------------------------------
if stage == "facts":
    facts = {"budget": None, "ledger": None}
    text = read(requirements_path)
    if text is not None:
        budget, _ = budget_of(text)
        if budget:
            facts["budget"] = {"milestones": budget[0], "chunks": budget[1]}
    text = read(ledger_path)
    if text is not None:
        rows, _ = ledger_rows(text)
        if rows:
            facts["ledger"] = {"rows": len(rows), "kept_chunks": kept_chunks(rows)}
    print(json.dumps(facts, sort_keys=True))
    raise SystemExit(0)


# ---------------------------------------------------------------------------
# --stage scope: docs/REQUIREMENTS.md (PL1).
# ---------------------------------------------------------------------------
if stage == "scope":
    text = read(requirements_path)
    if text is None:
        print(f"plan-check: no {requirements_path} — run /scope first", file=sys.stderr)
        raise SystemExit(2)

    values = field(text, "Ambition")
    if len(values) == 1 and plain(values[0]).lower() in AMBITIONS:
        emit("ambition", "pass", f"ambition: {plain(values[0]).lower()}")
    else:
        emit("ambition", "fail",
             f"{len(values)} `**Ambition:**` line(s)" + (f", value `{values[0]}`" if len(values) == 1 else ""),
             "write exactly one `**Ambition:** toy | tool | product` line. The dial sets how much the "
             "rest of the plan may cost; without it the budget below has nothing to answer to")

    budget, error = budget_of(text)
    if budget:
        emit("budget", "pass", f"{budget[0]} milestone(s), {budget[1]} chunk(s)")
    else:
        emit("budget", "fail", error,
             "write one `**Complexity budget:** <n> milestones, <n> chunks` line. The architect's "
             "ledger and the roadmap are both held to it, so it must be a number")

    frs = defined_frs(text)
    if frs:
        emit("requirements", "pass", f"{len(frs)} functional requirement(s) defined")
    else:
        emit("requirements", "fail", "no `FR-<n>` is defined at the start of a list item or heading",
             "write each functional requirement as its own list item beginning `FR-<n>`")

    body = section(text, "Delight")
    named = sorted(set(re.findall(r"\bFR-\d+\b", "\n".join(body or []))))
    unknown = [fr for fr in named if fr not in frs]
    if body is None or not items(body):
        emit("delight", "fail", "no `## Delight` section with at least one item",
             "run the delight pass: name the requirement(s) that make v1 a pleasure rather than "
             "merely correct, as a `## Delight` list citing their FR ids")
    elif not named or unknown:
        emit("delight", "fail",
             "`## Delight` cites no FR id" if not named else f"`## Delight` cites undefined {', '.join(unknown)}",
             "cite each delight item by the FR id that delivers it, so the roadmap can plan it")
    else:
        emit("delight", "pass", f"delight carried by {', '.join(named)}")

    body = section(text, "Gold-plating pass")
    if body is not None and items(body):
        emit("gold-plating", "pass", f"{len(items(body))} item(s) recorded")
    else:
        emit("gold-plating", "fail", "no `## Gold-plating pass` section with at least one item",
             "for each requirement ask whether v1 fails its mission without it; record every cut as an "
             "item, or one `none: <why nothing was cut>` item")

    body = section(text, "Out of scope")
    if body is not None and items(body):
        emit("out-of-scope", "pass", f"{len(items(body))} non-goal(s)")
    else:
        emit("out-of-scope", "fail", "no `## Out of scope` section with at least one item",
             "list the explicit non-goals. An empty list means the probing failed: it is what bounds "
             "every agent downstream")


# ---------------------------------------------------------------------------
# --stage architect: docs/feasibility.md (PL2).
# ---------------------------------------------------------------------------
if stage == "architect":
    text = read(ledger_path)
    if text is None:
        print(f"plan-check: no {ledger_path} — /architect writes the feasibility ledger", file=sys.stderr)
        raise SystemExit(2)

    rows, error = ledger_rows(text)
    if rows is None or not rows:
        emit("ledger", "fail", error or "the ledger table has no rows",
             "write the ledger as one markdown table with exactly those columns, one row per component")
        rows = []
    else:
        emit("ledger", "pass", f"{len(rows)} component row(s)")

    problems = []
    for row in rows:
        name = plain(row["component"]) or "<unnamed>"
        empty = [c for c in LEDGER_COLUMNS if not plain(row[c])]
        if empty:
            problems.append(f"{name}: empty {', '.join(empty)}")
            continue
        verdict, tier, call = (plain(row[c]).lower() for c in ("verdict", "tier", "call"))
        if verdict not in VERDICTS:
            problems.append(f"{name}: verdict `{row['verdict']}` is not one of {'/'.join(VERDICTS)}")
        spike = plain(row["spike"])
        if verdict in ("proven", "disproven"):
            path = Path(spike)
            if (path.is_absolute() or ".." in path.parts or not path.parts
                    or path.parts[0] != "spikes" or not (project / path).is_dir()):
                problems.append(f"{name}: verdict {verdict} but spike `{spike}` is not an existing spikes/ directory")
        elif verdict == "not-spiked" and spike.lower() != "none":
            problems.append(f"{name}: not-spiked but names spike `{spike}` — write `none`")
        if not re.fullmatch(r"\d+", plain(row["chunks"])):
            problems.append(f"{name}: chunks `{row['chunks']}` is not a whole number")
        if tier not in TIERS:
            problems.append(f"{name}: tier `{row['tier']}` is not one of {'/'.join(TIERS)}")
        if call not in CALLS:
            problems.append(f"{name}: call `{row['call']}` is not one of {'/'.join(CALLS)}")
    if rows:
        if problems:
            emit("rows", "fail", "; ".join(problems),
                 "fix each named row. A verdict without its spike on disk is a claim nobody ran; a row "
                 "without a call has not been decided")
        else:
            emit("rows", "pass", "every row has an approach, prior art, a verdict backed by its spike, "
                 "an estimate, a tier, a cost and a call")

    body = section(text, "Decisions for you")
    if body is not None and items(body):
        emit("decisions", "pass", f"{len(items(body))} item(s)")
    else:
        emit("decisions", "fail", "no `## Decisions for you` section with at least one item",
             "list what surfaced that the operator must decide, or one `none` item")

    requirements = read(requirements_path)
    budget, error = budget_of(requirements) if requirements is not None else (None, "no docs/REQUIREMENTS.md")
    if budget is None:
        emit("budget-fit", "fail", f"the scope has no readable complexity budget: {error}",
             "run /scope (plan-check --stage scope) first; the ledger is held to its budget")
    elif rows and not problems:
        kept = kept_chunks(rows)
        if kept <= budget[1]:
            emit("budget-fit", "pass", f"kept estimate {kept} chunk(s) within the scope budget of {budget[1]}")
        else:
            emit("budget-fit", "fail", f"kept estimate {kept} chunk(s) exceeds the scope budget of {budget[1]}",
                 "cut, defer or swap components until the kept rows fit — or go back to /scope, raise the "
                 "ambition or the budget there, and say so. Do not edit the estimate to fit")
    else:
        emit("budget-fit", "skip", "the ledger rows are not valid, so there is no estimate to compare")


print(f"forge plan-check — {project}  (stage {stage})\n")
for check, status, evidence, action in results:
    print(f"  {status.upper():6} {check}")
    print(f"         {evidence}")
    if action and status != "pass":
        print(f"      -> {action}")
failed = sum(1 for r in results if r[1] == "fail")
print(f"\n  {'CLEAR' if not failed else 'FAIL'} — "
      f"{sum(1 for r in results if r[1] == 'pass')} pass, {failed} fail, "
      f"{sum(1 for r in results if r[1] == 'skip')} skip")
raise SystemExit(1 if failed else 0)
PY
