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
# the outcome is NO VERDICT. So is an error in this runner itself.
#
# A case ends when its command exits. Its output goes to files, not pipes, so a
# process that left the case's group and still holds that output cannot keep
# the runner waiting. Whatever the case left running in its own process group
# is killed then. One that runs past the timeout is killed the same way and
# FAILS, named as a timeout: a hang on an adversarial input is the kind of
# thing the probe is there to catch.
#
# The last line is the outcome, written to be the gate card's result. It names
# the cases that failed, and the commit it ran on when the project is a git
# checkout ("at <short sha>", "+dirty" if tracked files had changed). It never
# holds a character a double-quoted shell word would act on:
#   hermes kanban --board <board> complete <gate> --result "<last line>"
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
# At most a day: a larger number is a typo, and past ~2^63 Python cannot wait on it.
case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT_OK=0;;
  *) if [ "${#TIMEOUT}" -le 5 ] && [ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 86400 ]; then TIMEOUT_OK=1; else TIMEOUT_OK=0; fi;;
esac
[ "$TIMEOUT_OK" = 1 ] || { echo "probe-run: --timeout must be 1 to 86400 seconds, not '$TIMEOUT'" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "probe-run: python3 is not on PATH" >&2; exit 2; }

python3 - "$HERE" "$PROJECT" "$GATE" "$TIMEOUT" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import traceback

gate = sys.argv[3]
SHELL_UNSAFE = str.maketrans({c: "'" for c in '"$`\\'})


def result(line, code):
    # The last line is pasted into `--result "..."` on the gate card, so it
    # never carries a character a double-quoted shell word would act on.
    print(f"probe {gate}: {line}".translate(SHELL_UNSAFE))
    raise SystemExit(code)


def unrunnable(message):
    print(f"probe-run: {gate}: {message}", file=sys.stderr)
    result(f"NO VERDICT — {message}", 2)


def contains(path, needle):
    """Whether a file holds a byte string, read in chunks, never all at once."""
    keep = max(len(needle) - 1, 0)
    with open(path, "rb") as handle:
        carry = b""
        while chunk := handle.read(1 << 20):
            window = carry + chunk
            if needle in window:
                return True
            carry = window[-keep:] if keep else b""
    return False


def tail(path, lines=5, span=65536):
    with open(path, "rb") as handle:
        handle.seek(max(0, os.path.getsize(path) - span))
        text = handle.read().decode("utf-8", errors="replace")
    kept = [line for line in text.splitlines() if line.strip()][-lines:]
    return "\n".join(f"      | {line}" for line in kept)


def show(out_path, err_path):
    for label, path in (("stdout", out_path), ("stderr", err_path)):
        if os.path.getsize(path):
            shown = tail(path)
            if shown:
                print(f"      {label}:\n{shown}")


def kill_group(pid):
    # Whatever the case left in its process group goes with it. The group may
    # already be empty, or hold only the reaped leader, which some kernels
    # answer with EPERM rather than ESRCH.
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


def checkout(project):
    """The project commit a verdict is about: '<short sha>[+dirty]', or None."""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    def git(*args):
        return subprocess.run(["git", "-C", str(project), *args], capture_output=True,
                              text=True, env=env, stdin=subprocess.DEVNULL)
    try:
        top = git("rev-parse", "--show-toplevel")
        head = git("rev-parse", "--short", "HEAD")
        dirty = git("status", "--porcelain", "--untracked-files=no")
    except OSError:
        return None
    if top.returncode or head.returncode or Path(top.stdout.strip()).resolve() != project:
        return None
    return head.stdout.strip() + ("+dirty" if dirty.returncode or dirty.stdout.strip() else "")


def main():
    # No bytecode beside the runtime's scripts, and none from a Python case into
    # its own input: that directory is frozen, so a .pyc there would leave the
    # next run at the gate with no verdict.
    sys.dont_write_bytecode = True
    sys.path.insert(0, sys.argv[1])
    from forge_probe import IGNORED, probe_path, validate_probe

    project = Path(sys.argv[2]).resolve()
    timeout = int(sys.argv[4])
    rel = probe_path(gate)
    case_env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")

    probe, digests, error = validate_probe(project, gate)
    if error:
        unrunnable(error.removeprefix(f"{gate}: "))

    # The planned probe, and only it: every file it would freeze must be in the
    # manifest with the same bytes, and nothing the manifest froze under it may
    # be gone. Anything else is a probe nobody approved.
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

    # Read before any case runs: a case may itself touch the checkout.
    at = checkout(project)
    where = f" at {at}" if at else ""
    print(f"probe {gate}: {rel} ({len(probe['cases'])} cases, frozen){where}")
    passed = {"realistic": 0, "adversarial": 0}
    total = {"realistic": 0, "adversarial": 0}
    failed, unstarted = [], []
    with tempfile.TemporaryDirectory(prefix="forge-probe-") as scratch:
        for index, case in enumerate(probe["cases"]):
            kind, name, expect = case["kind"], case["name"], case["expect"]
            total[kind] += 1
            argv = [arg.replace("{input}", case["input"]) for arg in case["run"]]
            label = f"{name} ({kind}{', ' + str(case['records']) + ' records' if kind == 'realistic' else ''})"
            out_path = os.path.join(scratch, f"{index}.out")
            err_path = os.path.join(scratch, f"{index}.err")
            # Output goes to files, not pipes: a case ends when its command
            # exits, whatever it left behind holding its output, and nothing is
            # held in memory. Its own process group, so what it leaves running
            # in that group is killed with it.
            with open(out_path, "wb") as out, open(err_path, "wb") as err:
                try:
                    proc = subprocess.Popen(argv, cwd=project, env=case_env,
                                            stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                            start_new_session=True)
                except OSError as exc:
                    reason = f"case '{name}' could not start {argv[0]!r}: {exc.strerror or exc}"
                    print(f"ERROR {label} — could not start {argv[0]!r}: {exc.strerror or exc}")
                    unstarted.append(reason)
                    continue
                try:
                    proc.wait(timeout=timeout)
                    timed_out = False
                except subprocess.TimeoutExpired:
                    timed_out = True
                kill_group(proc.pid)
                proc.kill()  # in case the leader left its own group; a no-op once it has exited
                proc.wait()
            if timed_out:
                print(f"FAIL  {label} — timed out after {timeout}s; expected exit {expect['exit']}")
                show(out_path, err_path)
                failed.append(name)
                continue
            misses = []
            if proc.returncode != expect["exit"]:
                misses.append(f"exit {proc.returncode}, expected {expect['exit']}")
            if "stdout" in expect and not contains(out_path, expect["stdout"].encode("utf-8")):
                misses.append(f"stdout lacks {expect['stdout']!r}")
            if misses:
                print(f"FAIL  {label} — {'; '.join(misses)}")
                show(out_path, err_path)
                failed.append(name)
            else:
                passed[kind] += 1
                print(f"PASS  {label}")

    ok = sum(passed.values())
    count = sum(total.values())
    if unstarted:
        ran = count - len(unstarted)
        also = f"; {len(failed)} of the {ran} cases that ran also failed: {', '.join(failed)}" if failed else ""
        unrunnable(unstarted[0] + also)
    named = f"; failed: {', '.join(failed)}" if failed else ""
    result(f"{'PASS' if ok == count else 'FAIL'} — {ok} of {count} cases passed "
           f"(realistic {passed['realistic']}/{total['realistic']}, "
           f"adversarial {passed['adversarial']}/{total['adversarial']}){named}{where}",
           0 if ok == count else 1)


try:
    main()
except SystemExit:
    raise
except Exception as exc:  # a runner bug is not a finding about the milestone
    traceback.print_exc()
    unrunnable(f"runner error: {type(exc).__name__}: {exc}")
PY
