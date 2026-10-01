"""forge.probe.v1, defined once (epic MS2).

A milestone gate's probe is `tests/probes/gate_<milestone>.json`. Two scripts
read it, and they must agree on what a valid one is:

    acceptance-freeze.sh   validates it at plan time and hashes it, with every
                           input file, into docs/chunks/contract-freeze.json
    probe-run.sh           executes it on the gate card, and refuses one that
                           is not what the plan froze

So the rules live here, and both import them. A second copy would drift the
first time one end is edited (F30's defect class).
"""
import hashlib
import json
import os
from pathlib import Path

SCHEMA = "forge.probe.v1"
# Never part of a probe, at freeze time or at run time: Finder writes one into
# any directory the operator opens, and a frozen input that gained one would
# leave the gate with no verdict.
IGNORED = frozenset({".DS_Store"})


def probe_path(gate_id):
    """The probe's repo-relative path, derived from the gate id, never chosen."""
    return f"tests/probes/{gate_id.lower().replace('-', '_')}.json"


def text(value):
    """A string that survives being written out: no lone surrogates from a JSON escape."""
    if not isinstance(value, str):
        return False
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def case_files(project, given):
    """(files, error) for a case's input: every file it holds, sorted.

    A symlink anywhere in an input is refused. Its target's bytes are not what
    the freeze would hash (a linked directory is not even walked), so a frozen
    probe could change underneath its manifest.
    """
    target = project / given
    if not target.exists() and not target.is_symlink():
        return None, f"input {given} does not exist"
    if target.is_symlink():
        return None, f"input {given} is a symlink, which cannot be frozen"
    if target.is_file():
        return [target], None
    files = []
    for root, dirs, names in os.walk(target, followlinks=False):
        for entry in sorted(dirs + names):
            path = Path(root) / entry
            if path.is_symlink():
                rel = path.relative_to(project).as_posix()
                return None, f"input {given} holds a symlink, {rel}, which cannot be frozen"
        files += [Path(root) / n for n in names if n not in IGNORED]
    if not files:
        return None, f"input {given} holds no files"
    return sorted(files), None


def names_an_ignored_file(arg):
    return any(part in IGNORED for part in arg.replace("\\", "/").split("/"))


def validate_probe(project, gate_id):
    """(probe, digests, error) for a gate's forge.probe.v1 declaration.

    digests maps the probe file and every input file to its SHA-256: exactly
    what acceptance-freeze freezes and what probe-run checks before it runs.
    """
    rel = probe_path(gate_id)
    path = project / rel
    try:
        raw = path.read_bytes()
        probe = json.loads(raw.decode("utf-8"))
    except FileNotFoundError:
        return None, None, f"{gate_id}: missing probe; expected {rel}"
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return None, None, f"{gate_id}: cannot read {rel}: {exc}"
    milestone = gate_id.removeprefix("GATE-")
    if not isinstance(probe, dict) or probe.get("probe") != SCHEMA:
        return None, None, f"{gate_id}: {rel} is not a {SCHEMA} object"
    if probe.get("milestone") != milestone:
        return None, None, f"{gate_id}: {rel} names milestone {probe.get('milestone')!r}, expected {milestone!r}"
    cases = probe.get("cases")
    if not isinstance(cases, list) or not cases:
        return None, None, f"{gate_id}: {rel} has no cases"
    digests = {rel: hashlib.sha256(raw).hexdigest()}
    names, kinds = set(), set()
    for index, case in enumerate(cases, start=1):
        where = f"{gate_id}: {rel} case {index}"
        if not isinstance(case, dict):
            return None, None, f"{where} is not an object"
        name = case.get("name")
        if not text(name) or not name.strip() or name in names:
            return None, None, f"{where} needs a unique, non-empty name"
        names.add(name)
        kind = case.get("kind")
        if kind not in ("realistic", "adversarial"):
            return None, None, f"{where} kind must be realistic or adversarial, not {kind!r}"
        kinds.add(kind)
        records = case.get("records")
        if kind == "realistic" and (not isinstance(records, int) or isinstance(records, bool) or records < 2):
            return None, None, f"{where} is realistic and must declare records >= 2 (a one-record fixture cannot aggregate)"
        run = case.get("run")
        if (not isinstance(run, list) or not run
                or not all(text(arg) and arg and "\x00" not in arg for arg in run)
                or not any("{input}" in arg for arg in run)):
            return None, None, f"{where} run must be a non-empty argv of strings that names {{input}}"
        ignored = next((arg for arg in run if names_an_ignored_file(arg)), None)
        if ignored is not None:
            return None, None, f"{where} run names {ignored!r}, a file that is never part of a probe"
        expect = case.get("expect")
        if (not isinstance(expect, dict)
                or not isinstance(expect.get("exit"), int) or isinstance(expect.get("exit"), bool)
                or not set(expect) <= {"exit", "stdout"}
                or ("stdout" in expect and not text(expect["stdout"]))):
            return None, None, f"{where} expect must be {{\"exit\": <int>}} with an optional \"stdout\" substring"
        # Two expectations that cannot discriminate: an exit no process returns,
        # and an empty substring, which every output contains.
        if not 0 <= expect["exit"] <= 255:
            return None, None, f"{where} expect exit {expect['exit']} is not an exit status (0-255)"
        if expect.get("stdout") == "":
            return None, None, f"{where} expect stdout is empty, which every output contains"
        given = case.get("input")
        input_path = Path(given) if text(given) and given else None
        if (input_path is None or input_path.is_absolute() or ".." in input_path.parts
                or input_path.parts[:2] != ("tests", "probes")):
            return None, None, f"{where} input must be a path under tests/probes/, not {given!r}"
        files, error = case_files(project, input_path)
        if error:
            return None, None, f"{where} {error}"
        for file in files:
            rel_file = file.relative_to(project).as_posix()
            try:
                digests[rel_file] = hashlib.sha256(file.read_bytes()).hexdigest()
            except OSError as exc:
                return None, None, f"{where} input file {rel_file} cannot be read: {exc.strerror or exc}"
    missing = {"realistic", "adversarial"} - kinds
    if missing:
        return None, None, f"{gate_id}: {rel} has no {' and no '.join(sorted(missing))} case"
    return probe, digests, None
