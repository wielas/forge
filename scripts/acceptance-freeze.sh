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
#   ./scripts/acceptance-freeze.sh --check-base <base-dir> <head-dir>
#
# Exit: 0 acceptance is valid and the manifest was written,
#       1 a planned contract is invalid, or an implementation changed its freeze,
#       2 the command could not inspect the plan.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }

PROJECT=""; CHECK_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check-base) CHECK_BASE="${2:?--check-base needs the approved base directory}"; shift 2;;
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
[ -z "$CHECK_BASE" ] || [ -d "$CHECK_BASE" ] || {
  echo "acceptance-freeze: no such base directory: $CHECK_BASE" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "acceptance-freeze: python3 is not on PATH" >&2
  exit 2
}

python3 - "$PROJECT" "$CHECK_BASE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile


project = Path(sys.argv[1]).resolve()
check_base = Path(sys.argv[2]).resolve() if sys.argv[2] else None
chunk_dir = project / "docs" / "chunks"
graph_path = chunk_dir / "graph.json"
manifest_path = chunk_dir / "contract-freeze.json"


def fatal(message: str) -> None:
    print(f"acceptance-freeze: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_manifest(root: Path, role: str):
    path = root / "docs" / "chunks" / "contract-freeze.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, f"{role} docs/chunks/contract-freeze.json is unreadable: {exc}"
    if not isinstance(value, dict):
        return None, f"{role} docs/chunks/contract-freeze.json is not a JSON object"

    errors = []
    for feature, digest in value.items():
        feature_path = Path(feature) if isinstance(feature, str) else None
        if (
            feature_path is None
            or feature_path.is_absolute()
            or ".." in feature_path.parts
            or feature_path.suffix != ".feature"
        ):
            errors.append(f"{role} manifest has invalid feature path {feature!r}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            errors.append(f"{role} manifest has invalid SHA-256 for {feature!r}")
    if errors:
        return None, "; ".join(errors)
    return value, None


def load_graph_ids(root: Path, role: str):
    path = root / "docs" / "chunks" / "graph.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, f"{role} docs/chunks/graph.json is unreadable: {exc}"
    if not isinstance(value, list) or not value:
        return None, f"{role} docs/chunks/graph.json is not a non-empty array"
    ids = []
    for index, entry in enumerate(value):
        chunk_id = entry.get("id") if isinstance(entry, dict) else None
        if not isinstance(chunk_id, str) or not re.fullmatch(
            r"CHUNK-[A-Za-z0-9][A-Za-z0-9._-]*", chunk_id
        ):
            return None, f"{role} graph entry {index} has invalid id {chunk_id!r}"
        ids.append(chunk_id)
    if len(ids) != len(set(ids)):
        return None, f"{role} graph contains duplicate chunk ids"
    return ids, None


def contract_acceptance_surface(root: Path, chunk_id: str, role: str):
    path = root / "docs" / "chunks" / f"{chunk_id}.md"
    try:
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except (OSError, UnicodeError) as exc:
        return None, f"{role} {path.relative_to(root)} is unreadable: {exc}"

    starts = [
        index for index, line in enumerate(lines)
        if re.match(r"^-\s+\*\*Scenarios:\*\*", line)
    ]
    real_sources = [
        line.rstrip("\r\n") for line in lines
        if re.match(r"^-\s+\*\*Real sources:\*\*", line)
    ]
    acceptance = [
        line.rstrip("\r\n") for line in lines
        if re.match(r"^-\s+\*\*Acceptance:\*\*", line)
    ]
    if len(starts) != 1 or len(real_sources) != 1 or len(acceptance) != 1:
        return None, (
            f"{role} {path.relative_to(root)} must contain exactly one Scenarios, "
            "Real sources, and Acceptance field"
        )
    start = starts[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"^-\s+\*\*", lines[index]):
            end = index
            break
    return {
        "scenarios": "".join(lines[start:end]),
        "real_sources": real_sources[0],
        "acceptance": acceptance[0],
    }, None


if check_base is not None:
    base_manifest, base_error = load_manifest(check_base, "approved base")
    if base_error:
        fatal(base_error)
    base_ids, base_graph_error = load_graph_ids(check_base, "approved base")
    if base_graph_error:
        fatal(base_graph_error)

    # A corrupt base is a substrate failure, not a verdict on the implementation.
    # The planning receipt must describe the actual bytes at the approved commit.
    for feature, expected_digest in sorted(base_manifest.items()):
        base_feature = check_base / feature
        try:
            actual_digest = hashlib.sha256(base_feature.read_bytes()).hexdigest()
        except OSError as exc:
            fatal(f"approved base {feature} is unreadable: {exc}")
        if actual_digest != expected_digest:
            fatal(
                f"approved base {feature} does not match its manifest digest "
                f"{expected_digest}"
            )

    errors = []
    head_manifest, head_error = load_manifest(project, "implementation head")
    if head_error:
        errors.append(head_error)
        head_manifest = {}

    for feature in sorted(set(base_manifest) | set(head_manifest)):
        base_digest = base_manifest.get(feature)
        head_digest = head_manifest.get(feature)
        if base_digest != head_digest:
            errors.append(
                f"{feature}: manifest digest differs from the approved base "
                f"({base_digest or '<missing>'} -> {head_digest or '<missing>'})"
            )

    for feature, expected_digest in sorted(base_manifest.items()):
        head_feature = project / feature
        try:
            actual_digest = hashlib.sha256(head_feature.read_bytes()).hexdigest()
        except OSError as exc:
            errors.append(f"{feature}: implementation feature is unreadable: {exc}")
            continue
        if actual_digest != expected_digest:
            errors.append(
                f"{feature}: feature bytes differ from the approved base digest "
                f"{expected_digest}"
            )

    # The contract prose is one of ADR-0014's three acceptance artifacts. Keep
    # ordinary fields such as Touches amendable/advisory, but freeze the exact
    # Scenarios block, explicit source mapping, and Acceptance path.
    for chunk_id in sorted(base_ids):
        base_surface, base_surface_error = contract_acceptance_surface(
            check_base, chunk_id, "approved base"
        )
        if base_surface_error:
            fatal(base_surface_error)
        head_surface, head_surface_error = contract_acceptance_surface(
            project, chunk_id, "implementation head"
        )
        if head_surface_error:
            errors.append(head_surface_error)
            continue
        if base_surface != head_surface:
            errors.append(
                f"docs/chunks/{chunk_id}.md: contract acceptance surface differs "
                "from the approved base (Scenarios, Real sources, or Acceptance)"
            )

    if errors:
        for error in dict.fromkeys(errors):
            print(f"acceptance-freeze: {error}", file=sys.stderr)
        raise SystemExit(1)

    print(
        "acceptance-freeze: implementation matches approved base "
        f"({len(base_manifest)} contract(s))"
    )
    raise SystemExit(0)


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


def feature_scenarios(chunk_id: str, feature_text: str):
    scenarios = []
    pending_tags = set()
    current = None
    for line in feature_text.splitlines():
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
    tagged = {
        index for index, scenario in enumerate(scenarios, start=1)
        if "real-source" in scenario["tags"]
    }
    return (parsed, tagged), None


def contract_real_sources(chunk_id: str, contract: str):
    match = re.search(
        r"(?m)^-\s+\*\*Real sources:\*\*\s+(.+?)\s*$", contract
    )
    if match is None:
        return None, f"{chunk_id}: missing Real sources declaration"
    declaration = match.group(1).strip()
    if declaration.lower() == "none":
        return [], None

    sources = []
    seen = set()
    for item in declaration.split(";"):
        item = item.strip()
        parsed = re.fullmatch(
            r"`([^`]+)`\s*(?:→|->)\s*scenario\s+([1-9][0-9]*)",
            item,
            re.IGNORECASE,
        )
        if parsed is None:
            return None, (
                f"{chunk_id}: invalid Real sources entry {item!r}; expected "
                "`source label` → scenario N"
            )
        label = parsed.group(1).strip()
        key = label.casefold()
        if not label or key in seen:
            return None, f"{chunk_id}: duplicate or empty real source {label!r}"
        seen.add(key)
        sources.append((label, int(parsed.group(2))))
    return sources, None


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
    try:
        feature_bytes = feature_path.read_bytes()
        feature_text = feature_bytes.decode("utf-8")
    except FileNotFoundError:
        errors.append(f"{chunk_id}: missing feature; expected {expected}")
        continue
    except (OSError, UnicodeError) as exc:
        errors.append(f"{chunk_id}: cannot read {expected}: {exc}")
        continue

    planned, contract_error = contract_scenarios(chunk_id, contract)
    if contract_error:
        errors.append(contract_error)
        continue
    real_sources, source_error = contract_real_sources(chunk_id, contract)
    if source_error:
        errors.append(source_error)
        continue
    generated, feature_error = feature_scenarios(chunk_id, feature_text)
    if feature_error:
        errors.append(feature_error)
        continue
    actual_steps, tagged_indexes = generated
    if planned != actual_steps:
        errors.append(
            f"{chunk_id}: feature steps do not match the contract's Given/When/Then scenarios"
        )
        continue
    out_of_range = [
        f"{label} → scenario {index}"
        for label, index in real_sources if index > len(planned)
    ]
    if out_of_range:
        errors.append(
            f"{chunk_id}: Real sources maps beyond its {len(planned)} scenario(s): "
            + ", ".join(out_of_range)
        )
        continue
    declared_indexes = {index for _, index in real_sources}
    if declared_indexes != tagged_indexes:
        errors.append(
            f"{chunk_id}: @real-source scenarios {sorted(tagged_indexes)} do not "
            f"match declared source scenarios {sorted(declared_indexes)}"
        )
        continue

    features[expected] = hashlib.sha256(feature_bytes).hexdigest()

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
