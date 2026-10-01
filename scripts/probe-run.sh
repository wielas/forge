#!/usr/bin/env bash
# =============================================================================
# forge probe-run — execute a milestone gate's frozen probe (epic MS2).
#
# /roadmap declares each milestone's probe as tests/probes/gate_<milestone>.json
# (forge.probe.v1, defined once in scripts/forge_probe.py), and
# acceptance-freeze hashes it, with every input file, into
# docs/chunks/contract-freeze.json. This runs it on the gate card, once every
# chunk of the milestone is merged. Each case's `run` argv runs from the
# project root, with `{input}` replaced by the case's input path, stdin closed
# and no shell. Its exit code is compared exactly, and `stdout`, when the case
# declares one, is looked for as a substring of what it printed.
#
# It runs only the planned probe: the one the project's manifest holds. A probe
# or input file that differs from the manifest, or that the manifest never
# froze, has no verdict: that is exit 2, not a finding. The manifest itself is
# trusted as merged; what keeps an implementation branch from re-freezing a
# weaker probe is `acceptance-freeze --check-base` at review (ADR-0014).
#
# A case whose command cannot be started at all — a missing `uv` — has no
# verdict either, because that is not a defect in the milestone. Every other
# case still runs and is reported, so a finding is never hidden behind it, but
# the outcome is NO VERDICT. A case ends when its command exits and its output
# closes. One that runs past the timeout has its process group killed and
# FAILS, named as a timeout: a hang on an adversarial input is the kind of
# thing the probe is there to catch.
#
# The last line is the outcome, written to be the gate card's result:
#   hermes kanban --board <board> complete <gate> --result "probe: <last line>"
#
# Usage:
#   ./scripts/probe-run.sh <project-dir> GATE-<milestone> [--timeout <seconds>]
#
# Exit: 0 every case met its expectation — the probe passes,
#       1 at least one case did not — the probe found something,
#       2 the probe could not be run, so there is no verdict.
# =============================================================================
set -uo pipefail

helptext() { awk 'NR>2 && /^# ={10,}/{exit} NR>2' "$0"; }
usagetext() { awk '/^# Usage:/{u=1} u && /^# ={10,}/{exit} u' "$0"; }

# Resolve through symlinks first: forge_probe.py lives beside the TARGET.
_self="${BASH_SOURCE[0]:-$0}"
while [ -L "$_self" ]; do
  _link="$(readlink "$_self")"
  case "$_link" in /*) _self="$_link";; *) _self="$(dirname "$_self")/$_link";; esac
done
HERE="$(cd "$(dirname "$_self")" 2>/dev/null && pwd -P)" \
  || { echo "probe-run: script directory cannot be resolved" >&2; exit 2; }
PROJECT=""; GATE=""; TIMEOUT=600
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ $# -ge 2 ] || { echo "probe-run: --timeout needs a number of seconds" >&2; exit 2; }
      TIMEOUT="$2"; shift 2;;
    -h|--help) helptext; exit 0;;
    -*) echo "probe-run: unknown argument: $1" >&2; exit 2;;
    *) if [ -z "$PROJECT" ]; then PROJECT="$1"
       elif [ -z "$GATE" ]; then GATE="$1"
       else echo "probe-run: unexpected argument: $1" >&2; exit 2
       fi
       shift;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$GATE" ] || { usagetext >&2; exit 2; }
[ -d "$PROJECT" ] || { echo "probe-run: no such project directory: $PROJECT" >&2; exit 2; }
# The id graph.json allows for a gate, and nothing that could leave tests/probes/.
gate_re='^GATE-[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $GATE =~ $gate_re ]] || { echo "probe-run: '$GATE' is not a gate id (GATE-<milestone>)" >&2; exit 2; }
case "$TIMEOUT" in
  ''|*[!0-9]*|0) echo "probe-run: --timeout must be a positive number of seconds, not '$TIMEOUT'" >&2; exit 2;;
esac
command -v python3 >/dev/null 2>&1 || { echo "probe-run: python3 is not on PATH" >&2; exit 2; }

python3 - "$HERE" "$PROJECT" "$GATE" "$TIMEOUT" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

# No bytecode beside the runtime's scripts, and none from a Python case into its
# own input: that directory is frozen, so a .pyc there would leave the next run
# at the gate with no verdict.
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from forge_probe import IGNORED, probe_path, validate_probe  # noqa: E402

case_env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")

project = Path(sys.argv[2]).resolve()
gate = sys.argv[3]
timeout = int(sys.argv[4])
rel = probe_path(gate)


def unrunnable(message):
    print(f"probe-run: {gate}: {message}", file=sys.stderr)
    print(f"probe {gate}: NO VERDICT — {message}")
    raise SystemExit(2)


probe, digests, error = validate_probe(project, gate)
if error:
    unrunnable(error.removeprefix(f"{gate}: "))

# The planned probe, and only it: every file it would freeze must be in the
# manifest with the same bytes, and nothing the manifest froze under it may be
# gone. Anything else is a probe nobody approved.
manifest_rel = "docs/chunks/contract-freeze.json"
try:
    manifest = json.loads((project / manifest_rel).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    unrunnable(f"cannot read {manifest_rel}: {exc}")
if not isinstance(manifest, dict):
    unrunnable(f"{manifest_rel} is not a JSON object")
for path, digest in sorted(digests.items()):
    if path not in manifest:
        unrunnable(f"{path} is not in {manifest_rel}; run acceptance-freeze on the plan first")
    if manifest[path] != digest:
        unrunnable(f"{path} differs from its frozen digest in {manifest_rel}")
inputs = {Path(case["input"]).parts for case in probe["cases"]}
for path in sorted(manifest):
    parts = Path(path).parts
    if parts and parts[-1] in IGNORED:
        continue  # frozen before it was ignored; never part of a probe
    if path == rel or any(parts[:len(i)] == i for i in inputs):
        if path not in digests:
            unrunnable(f"{path} is frozen in {manifest_rel} but no longer exists")


def tail(text, lines=5):
    kept = [line for line in text.splitlines() if line.strip()][-lines:]
    return "\n".join(f"      | {line}" for line in kept)


def show(out, err):
    if out.strip():
        print("      stdout:\n" + tail(out))
    if err.strip():
        print("      stderr:\n" + tail(err))


print(f"probe {gate}: {rel} ({len(probe['cases'])} cases, frozen)")
passed = {"realistic": 0, "adversarial": 0}
total = {"realistic": 0, "adversarial": 0}
unstarted = []
for case in probe["cases"]:
    kind, name, expect = case["kind"], case["name"], case["expect"]
    total[kind] += 1
    argv = [arg.replace("{input}", case["input"]) for arg in case["run"]]
    label = f"{name} ({kind}{', ' + str(case['records']) + ' records' if kind == 'realistic' else ''})"
    # Its own process group, so a timeout kills what the command started too:
    # `uv run python ...` leaves a grandchild holding the pipes otherwise.
    try:
        proc = subprocess.Popen(argv, cwd=project, env=case_env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                encoding="utf-8", errors="replace", start_new_session=True)
    except OSError as exc:
        reason = f"case '{name}' could not start {argv[0]!r}: {exc.strerror or exc}"
        print(f"ERROR {label} — could not start {argv[0]!r}: {exc.strerror or exc}")
        unstarted.append(reason)
        continue
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # the group ended between the timeout and the kill
        out, err = proc.communicate()
        print(f"FAIL  {label} — timed out after {timeout}s; expected exit {expect['exit']}")
        show(out, err)
        continue
    misses = []
    if proc.returncode != expect["exit"]:
        misses.append(f"exit {proc.returncode}, expected {expect['exit']}")
    if "stdout" in expect and expect["stdout"] not in out:
        misses.append(f"stdout lacks {expect['stdout']!r}")
    if misses:
        print(f"FAIL  {label} — {'; '.join(misses)}")
        show(out, err)
    else:
        passed[kind] += 1
        print(f"PASS  {label}")

ok = sum(passed.values())
count = sum(total.values())
ran = count - len(unstarted)
if unstarted:
    found = ran - ok
    also = f"; {found} of the {ran} cases that ran also failed" if found else ""
    unrunnable(unstarted[0] + also)
verdict = "PASS" if ok == count else "FAIL"
print(f"probe {gate}: {verdict} — {ok} of {count} cases passed "
      f"(realistic {passed['realistic']}/{total['realistic']}, "
      f"adversarial {passed['adversarial']}/{total['adversarial']})")
raise SystemExit(0 if ok == count else 1)
PY
