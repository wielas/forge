#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema==4.26.0"]
# ///
"""Validate one completed-run metadata envelope against its producer contract."""

from __future__ import annotations

import argparse
from collections import Counter
import json
import re
import sys
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.exceptions import SchemaError


ROOT = Path(__file__).resolve().parent.parent
RUBRICS = ROOT / "rubrics"
CONTRACT_PATH = RUBRICS / "run-metadata-contract.json"
CHUNK_ID = re.compile(r"^CHUNK-([0-9]+)$")
CHUNK_BRANCH = re.compile(r"^chunk/([0-9]+)-[a-z0-9]+(?:-[a-z0-9]+)*$")
PR_URL = re.compile(
    r"^https://github\.com/(?P<repo>[^/\s]+/[^/\s]+)/pull/(?P<number>[1-9][0-9]*)$"
)


class ContractError(Exception):
    """The versioned contract itself is missing or internally inconsistent."""


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ContractError(f"missing {path.relative_to(ROOT)}") from exc
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
        raise ValueError(f"metadata file does not exist: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"metadata is not JSON: {exc.msg} at line {exc.lineno}") from exc


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
        if chunk and branch and chunk.group(1) != branch.group(1):
            errors.append("branch: numeric id does not match chunk_id")

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
            if branch and chunk and chunk.group(1) != branch.group(1):
                errors.append("branch: numeric id does not match chunk")
    return errors


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Validate Forge completed-run metadata without opening a board."
    )
    result.add_argument("metadata", nargs="?", help="JSON file, or - for stdin")
    result.add_argument("--profile", help="producer profile, e.g. forge-codex-lane")
    result.add_argument("--reason", help="validate one blocked-event reason string")
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


if __name__ == "__main__":
    raise SystemExit(main())
