#!/usr/bin/env -S uv run --locked --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema==4.26.0"]
# ///
"""Validate completed-run metadata against its producer contract."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import json
import re
import sys
from pathlib import Path
from typing import Any, TextIO

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError


ROOT = Path(__file__).resolve().parent.parent
RUBRICS = ROOT / "rubrics"
CONTRACT_PATH = RUBRICS / "run-metadata-contract.json"
# An id is not a decimal integer. JobApp's board runs `C6`, `C9.1` and `C10`, and
# the digits-only pair killed those runs at the TERMINATOR — the lane's SKILL.md
# §7 gates `kanban_complete` on this script exiting 0, so the envelope was
# refused after the PR was open and the whole chunk paid for. CHUNK_ID is the
# grammar hermes/board-bootstrap.sh and scripts/acceptance-freeze.sh already
# enforce on card ids; CHUNK_BRANCH is byte-identical to the rule in
# scripts/prejudge.sh, the template's branch-name.sh and chunk-handoff.schema.json.
#
# Both had to move together with the schemas. The agreement check below fires
# only when BOTH match, so widening the schemas alone would have let `CHUNK-C10`
# past a comparison that had silently stopped happening — measured: a C10
# chunk_id on a C9.1 branch validated clean.
CHUNK_ID = re.compile(r"^CHUNK-([A-Za-z0-9][A-Za-z0-9._-]*)$")
CHUNK_BRANCH = re.compile(r"^chunk/[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*-[a-z0-9]+(?:-[a-z0-9]+)*$")
PR_URL = re.compile(
    r"^https://github\.com/(?P<repo>[^/\s]+/[^/\s]+)/pull/(?P<number>[1-9][0-9]*)$"
)
RFC3339 = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)


class ContractError(Exception):
    """The versioned contract itself is missing or internally inconsistent."""


class UnreadableError(Exception):
    """A path could not be read at all, so nothing about it has been judged.

    Distinct from invalid metadata on purpose. Exit 1 means "this envelope is
    wrong" and a lane turns that into a block against the chunk; a directory
    passed where a file belongs is an operator fault, and reporting it as
    invalid metadata would blame the run for the harness's mistake.
    """


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ContractError(f"missing {path.relative_to(ROOT)}") from exc
    except OSError as exc:
        raise ContractError(f"cannot read {path.relative_to(ROOT)}: {exc.strerror}") from exc
    except json.JSONDecodeError as exc:
        raise ContractError(
            f"invalid JSON in {path.relative_to(ROOT)}: {exc.msg} at line {exc.lineno}"
        ) from exc


def load_contract() -> dict[str, Any]:
    value = read_json(CONTRACT_PATH)
    if not isinstance(value, dict):
        raise ContractError("rubrics/run-metadata-contract.json is not an object")
    if value.get("version") != 1:
        raise ContractError("run metadata contract version must be 1")
    pattern = value.get("blocked_reason_pattern")
    if not isinstance(pattern, str):
        raise ContractError("run metadata contract needs blocked_reason_pattern")
    try:
        re.compile(pattern)
    except re.error as exc:
        raise ContractError(f"blocked_reason_pattern is not a valid regex: {exc}") from exc
    if not isinstance(value.get("schemas"), dict) or not isinstance(
        value.get("profiles"), dict
    ):
        raise ContractError("run metadata contract needs object schemas and profiles maps")
    return value


def registered_schemas(contract: dict[str, Any]) -> dict[str, tuple[Path, dict[str, Any]]]:
    result: dict[str, tuple[Path, dict[str, Any]]] = {}
    for schema_id, filename in contract["schemas"].items():
        if not isinstance(schema_id, str) or not isinstance(filename, str):
            raise ContractError("schema ids and filenames must be strings")
        path = RUBRICS / filename
        schema = read_json(path)
        if not isinstance(schema, dict):
            raise ContractError(f"{path.relative_to(ROOT)} is not an object")
        declared = schema.get("properties", {}).get("schema", {}).get("const")
        if declared != schema_id:
            raise ContractError(
                f"{path.relative_to(ROOT)} declares schema const {declared!r}, "
                f"expected {schema_id!r}"
            )
        result[schema_id] = (path, schema)
    return result


def check_schemas(contract: dict[str, Any]) -> None:
    schemas = registered_schemas(contract)
    for path, schema in schemas.values():
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            raise ContractError(f"{path.relative_to(ROOT)} is not JSON Schema Draft 2020-12")
        try:
            Draft202012Validator.check_schema(schema)
        except SchemaError as exc:
            raise ContractError(f"invalid schema {path.relative_to(ROOT)}: {exc.message}") from exc

    for profile, outcomes in contract["profiles"].items():
        if not isinstance(profile, str) or not isinstance(outcomes, dict):
            raise ContractError("profile contracts must be objects keyed by profile name")
        allowed = outcomes.get("completed")
        if not isinstance(allowed, list) or not allowed:
            raise ContractError(f"profile {profile!r} has no completed schema list")
        if len(set(allowed)) != len(allowed) or not all(
            isinstance(schema_id, str) for schema_id in allowed
        ):
            raise ContractError(
                f"profile {profile!r} completed schema list must contain unique strings"
            )
        unknown = [schema_id for schema_id in allowed if schema_id not in schemas]
        if unknown:
            raise ContractError(f"profile {profile!r} references unknown schemas: {unknown}")


def instance_from(path_arg: str) -> Any:
    if path_arg == "-":
        try:
            return json.load(sys.stdin)
        except json.JSONDecodeError as exc:
            raise ValueError(f"stdin is not JSON: {exc.msg}") from exc
    path = Path(path_arg)
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as exc:
        # A lane writes this file itself in §7, so its absence is the run's own
        # fault and stays exit 1 — the producer really did fail to hand over an
        # envelope. Every other OS error below is about the path, not the run.
        raise ValueError(f"metadata file does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"metadata is not JSON: {exc.msg} at line {exc.lineno}") from exc
    except OSError as exc:
        raise UnreadableError(f"cannot read {path}: {exc.strerror}") from exc


def rfc3339_epoch(value: str) -> float:
    """Return a timezone-aware RFC3339 timestamp as Unix seconds."""
    if not RFC3339.fullmatch(value):
        raise ValueError("SINCE must be RFC3339, e.g. 2026-08-09T00:00:00Z")
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + ("+00:00" if value.endswith("Z") else ""))
    except ValueError as exc:
        raise ValueError(
            "SINCE must be RFC3339, e.g. 2026-08-09T00:00:00Z"
        ) from exc
    if parsed.utcoffset() is None:
        raise ValueError("SINCE must include an RFC3339 timezone offset")
    return parsed.timestamp()


def batch_stream(path_arg: str) -> tuple[TextIO, bool]:
    if path_arg == "-":
        return sys.stdin, False
    path = Path(path_arg)
    try:
        return path.open(), True
    except OSError as exc:
        raise UnreadableError(f"cannot read batch source {path}: {exc.strerror}") from exc


def batch_rows(path_arg: str) -> list[dict[str, Any]]:
    stream, close = batch_stream(path_arg)
    result: list[dict[str, Any]] = []
    try:
        for line_number, line in enumerate(stream, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise UnreadableError(
                    f"batch row {line_number} is not JSON: {exc.msg}"
                ) from exc
            if not isinstance(row, dict):
                raise UnreadableError(f"batch row {line_number} is not an object")
            result.append(row)
    except OSError as exc:
        raise UnreadableError(f"cannot read batch source: {exc.strerror}") from exc
    finally:
        if close:
            stream.close()
    return result


def row_identity(row: dict[str, Any]) -> str:
    task = row.get("task")
    run = row.get("run")
    return f"task={task if isinstance(task, str) and task else '<missing>'} run={run!s}"


def decoded_field(row: dict[str, Any], field: str) -> Any:
    raw = row.get(field)
    if raw is None or not isinstance(raw, str):
        return raw
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise UnreadableError(f"{field} is not JSON: {exc.msg}") from exc


def validate_batch(contract: dict[str, Any], path_arg: str, since: float) -> int:
    """Validate the JSON-lines projection produced by metadata-live.sh."""
    counts: Counter[str] = Counter()
    valid_envelopes: Counter[tuple[str, str]] = Counter()
    seen_profiles: set[str] = set()

    for position, row in enumerate(batch_rows(path_arg), start=1):
        kind = row.get("kind")
        if kind not in {"run", "block"}:
            raise UnreadableError(
                f"batch row {position} has unknown kind {kind!r}"
            )

        profile = row.get("profile")
        if kind == "run" and profile not in contract["profiles"]:
            # The board also contains operator and orchestration runs. They are
            # not completed-run producers until the registry says they are.
            continue

        at = row.get("at")
        if not isinstance(at, (int, float)) or isinstance(at, bool):
            counts["unjudged"] += 1
            print(f"unjudged {row_identity(row)}: event timestamp is unreadable")
            continue
        if at < since:
            counts["ignored"] += 1
            continue

        if kind == "run":
            assert isinstance(profile, str)  # registry membership above
            seen_profiles.add(profile)
            try:
                instance = decoded_field(row, "metadata")
            except UnreadableError as exc:
                counts["unjudged"] += 1
                print(f"unjudged {row_identity(row)} profile={profile}: {exc}")
                continue

            errors = validate_instance(contract, profile, instance)
            if errors:
                counts["invalid"] += 1
                print(
                    f"invalid {row_identity(row)} profile={profile}: "
                    + "; ".join(errors)
                )
                continue

            schema_id = instance["schema"]
            counts["valid"] += 1
            valid_envelopes[(profile, schema_id)] += 1
            continue

        try:
            payload = decoded_field(row, "payload")
        except UnreadableError as exc:
            counts["unjudged"] += 1
            print(f"unjudged {row_identity(row)}: {exc}")
            continue
        reason = payload.get("reason") if isinstance(payload, dict) else None
        if not isinstance(reason, str):
            counts["invalid"] += 1
            print(f"invalid {row_identity(row)}: blocked event has no string reason")
        elif not re.fullmatch(contract["blocked_reason_pattern"], reason):
            counts["invalid"] += 1
            print(
                f"invalid {row_identity(row)} reason={json.dumps(reason)}: "
                "blocked reason does not match blocked_reason_pattern"
            )
        else:
            counts["valid"] += 1

    for (profile, schema_id), count in sorted(valid_envelopes.items()):
        print(f"profile={profile} schema={schema_id} valid={count}")

    missing = sorted(set(contract["profiles"]) - seen_profiles)
    for profile in missing:
        print(f"missing producer={profile}: no post-cutoff completed run")

    print(
        "valid={valid} invalid={invalid} unjudged={unjudged} ignored={ignored}".format(
            valid=counts["valid"],
            invalid=counts["invalid"],
            unjudged=counts["unjudged"],
            ignored=counts["ignored"],
        )
    )
    if counts["unjudged"]:
        return 2
    if counts["invalid"] or missing:
        return 1
    return 0


def validate_instance(contract: dict[str, Any], profile: str, instance: Any) -> list[str]:
    if not isinstance(instance, dict):
        return ["metadata must be an object; completed producer runs may not store null"]

    profiles = contract["profiles"]
    if profile not in profiles:
        return [f"profile {profile!r} has no completed-run metadata contract"]

    schema_id = instance.get("schema")
    if not isinstance(schema_id, str):
        return ["metadata.schema must be a top-level string"]
    allowed = profiles[profile]["completed"]
    if schema_id not in allowed:
        return [
            f"profile {profile!r} may complete with {allowed}, not {schema_id!r}"
        ]

    schemas = registered_schemas(contract)
    _, schema = schemas[schema_id]
    errors = sorted(
        Draft202012Validator(schema).iter_errors(instance),
        key=lambda error: list(error.absolute_path),
    )
    rendered: list[str] = []
    for error in errors:
        location = ".".join(str(part) for part in error.absolute_path) or "$"
        rendered.append(f"{location}: {error.message}")
    if not rendered:
        rendered.extend(semantic_errors(schema_id, instance))
    return rendered


def semantic_errors(schema_id: str, instance: dict[str, Any]) -> list[str]:
    """Validate relationships JSON Schema cannot express without duplicating data."""
    errors: list[str] = []
    if schema_id == "forge.chunk.v1":
        scenarios = instance["scenarios"]
        if scenarios["passing"] > scenarios["added"]:
            errors.append("scenarios.passing: cannot exceed scenarios.added")
        chunk = CHUNK_ID.fullmatch(instance["chunk_id"])
        branch = CHUNK_BRANCH.fullmatch(instance["branch"])
        # Compared as a PREFIX, not as two extracted ids. The branch separator is
        # a hyphen, so `chunk/hello-1-greet` cannot be split back into id and
        # slug without knowing the id -- and here we do know it. Identical to the
        # old comparison for every numeric id, and correct for the rest.
        if chunk and branch and not instance["branch"].startswith(
            f"chunk/{chunk.group(1)}-"
        ):
            errors.append("branch: id does not match chunk_id")

    if schema_id == "forge.gate.v1":
        checks = instance["checks"]
        ids = [check["id"] for check in checks]
        if len(ids) != len(set(ids)):
            errors.append("checks: check ids must be unique")
        actual_counts = Counter(check["status"] for check in checks)
        expected_counts = {name: actual_counts[name] for name in instance["counts"]}
        if instance["counts"] != expected_counts:
            errors.append("counts: values must equal the checks status totals")
        expected_blocks = [check["id"] for check in checks if check["status"] == "block"]
        if instance["blocks"] != expected_blocks:
            errors.append("blocks: ids must equal blocking checks in check order")
        expected_result = "block" if expected_blocks else "clear"
        if instance["result"] != expected_result:
            errors.append(f"result: must be {expected_result!r} for these checks")

        pr = PR_URL.fullmatch(instance["pr"])
        if pr and instance["repo"] != pr.group("repo"):
            errors.append("repo: does not match pr URL")
        if pr and instance["number"] != int(pr.group("number")):
            errors.append("number: does not match pr URL")
        if instance["chunk"] is not None:
            chunk = CHUNK_ID.fullmatch(instance["chunk"])
            branch = CHUNK_BRANCH.fullmatch(instance["branch"])
            # A gate must be able to report the malformed branch it is blocking.
            # Only compare ids when the branch itself has the canonical shape.
            if branch and chunk and not instance["branch"].startswith(
                f"chunk/{chunk.group(1)}-"
            ):
                errors.append("branch: id does not match chunk")
    return errors


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Validate Forge completed-run metadata without opening a live board."
    )
    result.add_argument("metadata", nargs="?", help="JSON file, or - for stdin")
    result.add_argument("--profile", help="producer profile, e.g. forge-codex-lane")
    result.add_argument("--reason", help="validate one blocked-event reason string")
    result.add_argument(
        "--rfc3339-epoch",
        metavar="SINCE",
        help="validate a scoped-sweep cutoff and print Unix seconds",
    )
    result.add_argument(
        "--batch",
        metavar="JSONL",
        help="validate metadata-live JSON lines, or - for stdin",
    )
    result.add_argument(
        "--since",
        metavar="RFC3339",
        help="mandatory cutoff for --batch",
    )
    result.add_argument(
        "--check-schemas",
        action="store_true",
        help="validate the registry and every registered JSON Schema",
    )
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        contract = load_contract()
        check_schemas(contract)
        if args.rfc3339_epoch is not None:
            if (
                args.metadata
                or args.profile
                or args.reason is not None
                or args.check_schemas
                or args.batch
                or args.since
            ):
                parser().error(
                    "--rfc3339-epoch takes no other validation arguments"
                )
            try:
                epoch = rfc3339_epoch(args.rfc3339_epoch)
            except ValueError as exc:
                print(exc, file=sys.stderr)
                return 2
            print(int(epoch) if epoch.is_integer() else epoch)
            return 0
        if args.batch:
            if args.metadata or args.profile or args.reason is not None or args.check_schemas:
                parser().error(
                    "--batch takes no metadata, --profile, --reason or --check-schemas"
                )
            if args.since is None:
                parser().error("--batch requires --since RFC3339")
            try:
                since = rfc3339_epoch(args.since)
            except ValueError as exc:
                print(exc, file=sys.stderr)
                return 2
            return validate_batch(contract, args.batch, since)
        if args.since is not None:
            parser().error("--since is only valid with --batch")
        if args.check_schemas:
            if args.metadata or args.profile or args.reason is not None:
                parser().error("--check-schemas takes no metadata, --profile or --reason")
            return 0
        if args.reason is not None:
            if args.metadata or args.profile:
                parser().error("--reason takes no metadata or --profile")
            if re.fullmatch(contract["blocked_reason_pattern"], args.reason):
                return 0
            print("blocked reason does not match blocked_reason_pattern", file=sys.stderr)
            return 1
        if not args.metadata or not args.profile:
            parser().error("metadata and --profile are required")
        try:
            instance = instance_from(args.metadata)
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 1
        errors = validate_instance(contract, args.profile, instance)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        return 0
    except ContractError as exc:
        print(f"metadata contract error: {exc}", file=sys.stderr)
        return 2
    except UnreadableError as exc:
        print(f"metadata is unjudged: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
