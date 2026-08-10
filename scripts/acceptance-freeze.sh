#!/usr/bin/env bash
# =============================================================================
# forge acceptance-freeze — validate and hash acceptance emitted by /roadmap.
#
# The planning pass owns three representations of one contract:
#   docs/chunks/CHUNK-<id>.md                 the card body
#   tests/features/chunk_<id>.feature         executable acceptance
#   docs/chunks/contract-freeze.json          path -> SHA-256 of feature bytes
#
# This command validates the first two before atomically replacing the third.
# A failed run never rewrites the last good manifest.
#
# Usage:
#   ./scripts/acceptance-freeze.sh <project-dir>
#
# Exit: 0 acceptance is valid and the manifest was written,
#       1 a planned contract is incomplete or disagrees with its feature,
#       2 the command could not inspect the plan.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }

PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) helptext; exit 0;;
    -*) echo "acceptance-freeze: unknown argument: $1" >&2; exit 2;;
    *) [ -z "$PROJECT" ] || {
         echo "acceptance-freeze: only one project: got '$PROJECT' and '$1'" >&2
         exit 2
       }
       PROJECT="$1"; shift;;
  esac
done

[ -n "$PROJECT" ] || { usagetext >&2; exit 2; }
[ -d "$PROJECT" ] || {
  echo "acceptance-freeze: no such project directory: $PROJECT" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "acceptance-freeze: python3 is not on PATH" >&2
  exit 2
}

python3 - "$PROJECT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile


project = Path(sys.argv[1]).resolve()
chunk_dir = project / "docs" / "chunks"
graph_path = chunk_dir / "graph.json"
manifest_path = chunk_dir / "contract-freeze.json"


def fatal(message: str) -> None:
    print(f"acceptance-freeze: {message}", file=sys.stderr)
    raise SystemExit(2)


if not graph_path.is_file():
    fatal(f"no {graph_path} — run /roadmap first")

try:
    graph = json.loads(graph_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    fatal(f"cannot read {graph_path}: {exc}")

if not isinstance(graph, list) or not graph:
    fatal(f"{graph_path} is not a non-empty JSON array")

ids = []
for index, entry in enumerate(graph):
    if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
        fatal(f"graph entry {index} has no string id")
    chunk_id = entry["id"]
    if not re.fullmatch(r"CHUNK-[A-Za-z0-9][A-Za-z0-9._-]*", chunk_id):
        fatal(f"graph entry {index} has unsupported id {chunk_id!r}")
    ids.append(chunk_id)

if len(ids) != len(set(ids)):
    fatal("graph.json contains duplicate chunk ids")


def expected_feature(chunk_id: str) -> str:
    suffix = chunk_id.removeprefix("CHUNK-").lower().replace("-", "_")
    return f"tests/features/chunk_{suffix}.feature"


def normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip()).removesuffix(".")


def contract_scenarios(chunk_id: str, contract: str):
    bullets = []
    current = None
    in_scenarios = False
    for line in contract.splitlines():
        if re.match(r"^-\s+\*\*Scenarios:\*\*", line):
            in_scenarios = True
            continue
        if in_scenarios and re.match(r"^-\s+\*\*", line):
            break
        if not in_scenarios:
            continue
        match = re.match(r"^\s{2,}-\s+(.*)$", line)
        if match:
            current = match.group(1).strip()
            bullets.append(current)
        elif current is not None and re.match(r"^\s{4,}\S", line):
            current = f"{current} {line.strip()}"
            bullets[-1] = current

    if not bullets:
        return None, f"{chunk_id}: Scenarios has no Given/When/Then bullets"

    parsed = []
    pattern = re.compile(
        r"^Given\s+(.+?),\s*When\s+(.+?),\s*Then\s+(.+?)\.?$",
        re.IGNORECASE,
    )
    for bullet in bullets:
        match = pattern.match(bullet)
        if not match:
            return None, (
                f"{chunk_id}: scenario does not have one Given/When/Then shape: "
                f"{bullet}"
            )
        parsed.append(tuple(normalized(part) for part in match.groups()))
    return parsed, None


def feature_scenarios(chunk_id: str, feature_path: Path):
    scenarios = []
    pending_tags = set()
    current = None
    try:
        lines = feature_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return None, f"{chunk_id}: cannot read {feature_path}: {exc}"

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("@"):
            pending_tags.update(tag.removeprefix("@") for tag in stripped.split())
            continue
        if re.match(r"^Scenario:\s+\S", stripped, re.IGNORECASE):
            current = {"tags": pending_tags, "steps": []}
            pending_tags = set()
            scenarios.append(current)
            continue
        step = re.match(r"^(Given|When|Then)\s+(.+)$", stripped, re.IGNORECASE)
        if step:
            if current is None:
                return None, f"{chunk_id}: feature has a step outside a Scenario"
            current["steps"].append((step.group(1).lower(), normalized(step.group(2))))

    if not scenarios:
        return None, f"{chunk_id}: feature contains no Scenario blocks"

    parsed = []
    for index, scenario in enumerate(scenarios, start=1):
        steps = scenario["steps"]
        if [keyword for keyword, _ in steps] != ["given", "when", "then"]:
            return None, (
                f"{chunk_id}: feature scenario {index} must contain exactly one "
                "Given, When, and Then in that order"
            )
        parsed.append(tuple(text for _, text in steps))
    return (parsed, any("real-source" == tag for s in scenarios for tag in s["tags"])), None


external_source = re.compile(
    r"\b(?:Hermes|GitHub(?: CLI)?|gh CLI|kanban|SQLite?|subprocess|network|HTTP)\b",
    re.IGNORECASE,
)
errors = []
features = {}

for chunk_id in sorted(ids):
    contract_path = chunk_dir / f"{chunk_id}.md"
    expected = expected_feature(chunk_id)
    if not contract_path.is_file():
        errors.append(f"{chunk_id}: missing contract {contract_path.relative_to(project)}")
        continue
    try:
        contract = contract_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        errors.append(f"{chunk_id}: cannot read contract: {exc}")
        continue

    acceptance = re.search(
        r"(?m)^-\s+\*\*Acceptance:\*\*\s+`?([^`\s]+)`?\s*$", contract
    )
    if acceptance is None or acceptance.group(1) != expected:
        actual = acceptance.group(1) if acceptance is not None else "<missing>"
        errors.append(
            f"{chunk_id}: Acceptance is {actual}; expected {expected}"
        )
        continue

    feature_path = project / expected
    if not feature_path.is_file():
        errors.append(f"{chunk_id}: missing feature; expected {expected}")
        continue

    planned, contract_error = contract_scenarios(chunk_id, contract)
    if contract_error:
        errors.append(contract_error)
        continue
    generated, feature_error = feature_scenarios(chunk_id, feature_path)
    if feature_error:
        errors.append(feature_error)
        continue
    actual_steps, has_real_source = generated
    if planned != actual_steps:
        errors.append(
            f"{chunk_id}: feature steps do not match the contract's Given/When/Then scenarios"
        )
        continue
    if external_source.search(contract) and not has_real_source:
        errors.append(
            f"{chunk_id}: contract names an external source but {expected} has no "
            "@real-source Scenario"
        )
        continue

    features[expected] = hashlib.sha256(feature_path.read_bytes()).hexdigest()

if errors:
    for error in errors:
        print(f"acceptance-freeze: {error}", file=sys.stderr)
    raise SystemExit(1)

chunk_dir.mkdir(parents=True, exist_ok=True)
temporary = None
try:
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=chunk_dir, prefix=".contract-freeze.", delete=False
    ) as handle:
        temporary = Path(handle.name)
        json.dump(features, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary, 0o644)
    os.replace(temporary, manifest_path)
except OSError as exc:
    if temporary is not None:
        temporary.unlink(missing_ok=True)
    fatal(f"cannot write {manifest_path}: {exc}")

print(
    f"acceptance-freeze: wrote {manifest_path.relative_to(project)} "
    f"({len(features)} contract(s))"
)
PY
