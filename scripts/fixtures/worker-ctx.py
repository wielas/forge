#!/usr/bin/env python3
"""The two halves of a dispatched worker that `scripts/verify.sh` cannot get from bash.

A worker is a Hermes agent (the DRIVER) whose terminal is a fenced child (epic S6d,
P24): the driver's own tool calls are granted the task, the terminal's are not. The
programs under test (`lane.sh`, `prejudge-review.sh`) run in the terminal; the board
is written by the driver, through the tool the program's envelope names. So a case
needs, from the INSTALLED Hermes and never by hand:

  fenced-env <board> <task> <profile> [--branch B] [--poison]
      The environment a fenced terminal carries, as a shell snippet to `source` in
      a subshell. Built the way the dispatcher builds it (HERMES_KANBAN_TASK,
      _RUN_ID and _CLAIM_LOCK from the board; the DB, workspace, board, profile and
      HERMES_HOME of the profile pinned; the marker popped at the grant boundary,
      `kanban_db_dispatch.py`) and then passed through Hermes's own
      `agent.delegation_context.delegated_child_subprocess_env`, which scrubs the
      three and sets the marker. The marker is never set here.
      --poison then plants WRONG values for exactly `KANBAN_ENV_KEYS`, read from
      the installed module, so a program that reads a scrubbed variable (or falls
      back to one) acts on an id that is not this task's.

  perform <board> <task> <profile> <envelope.json>
      The driver, as a test plays it: in a dispatcher-GRANTED context (task, run
      and claim set, no marker) call the envelope's `terminate` through Hermes's
      real tool registry, verbatim; if that returns an error, call `on_error`.
      One JSON line per call. Exit 0 = `terminate` landed; 10 = it errored and
      `on_error` landed; 11 = nothing landed; 2 = usage.

  claim-review <board> <task>
      The dispatcher's own claim of a card in `review` (`claim_review_task`).

It refuses to run unless HERMES_HOME is an isolated directory: a case must never
reach the operator's boards or the running gateway.
"""
import json
import os
import shlex
import sys
from pathlib import Path

HERMES_SRC = Path(os.environ.get("FORGE_HERMES_SRC", str(Path.home() / ".hermes" / "hermes-agent")))
sys.path.insert(0, str(HERMES_SRC))

SESSION_ID = "s6d-lab-session-0001"


def die(msg, code=2):
    print(f"worker-ctx: {msg}", file=sys.stderr)
    sys.exit(code)


def isolated_home():
    home = os.environ.get("HERMES_HOME", "")
    if not home:
        die("HERMES_HOME is unset: refusing to touch the default home")
    real = (Path.home() / ".hermes").resolve()
    here = Path(home).resolve()
    if here == real or real in here.parents:
        die(f"HERMES_HOME {here} is the operator's own: refusing")
    return here


def ensure_profiles(root):
    # `kanban_request_review` refuses a reviewer with no profile identity marker.
    for name in ("forge-codex-lane", "forge-verifier"):
        d = root / "profiles" / name
        d.mkdir(parents=True, exist_ok=True)
        if not (d / "SOUL.md").exists():
            (d / "SOUL.md").write_text(f"# {name}\n")


def board_task(board, task):
    os.environ["HERMES_KANBAN_BOARD"] = board
    from hermes_cli import kanban_db as kb, kanban_db_connect as kbc
    with kbc.connect_closing() as conn:
        t = kb.get_task(conn, task)
    if t is None:
        die(f"no task {task} on board {board}")
    return kb, t


def granted_env(board, task, profile, branch=None):
    """The environment `_default_spawn` hands a worker (kanban_db_dispatch.py)."""
    root = isolated_home()
    ensure_profiles(root)
    kb, t = board_task(board, task)
    if t.current_run_id is None or not t.claim_lock:
        die(f"task {task} is not claimed: there is no run to grant")
    env = dict(os.environ)
    env.pop("HERMES_DELEGATED_CHILD_CONTEXT", None)   # the grant boundary pops it
    env.update(
        HERMES_KANBAN_TASK=t.id,
        HERMES_KANBAN_RUN_ID=str(t.current_run_id),
        HERMES_KANBAN_CLAIM_LOCK=t.claim_lock,
        HERMES_KANBAN_BOARD=board,
        HERMES_KANBAN_DB=str(kb.kanban_db_path(board=board)),
        HERMES_KANBAN_WORKSPACES_ROOT=str(kb.workspaces_root(board=board)),
        HERMES_KANBAN_WORKSPACE=t.workspace_path or "",
        HERMES_PROFILE=profile,
        HERMES_HOME=str(root / "profiles" / profile),
        HERMES_SESSION_SOURCE="kanban",
        HERMES_SESSION_ID=SESSION_ID,
    )
    b = branch or getattr(t, "branch_name", None)
    if b:
        env["HERMES_KANBAN_BRANCH"] = b
    return env


def cmd_fenced_env(argv):
    poison = "--poison" in argv
    argv = [a for a in argv if a != "--poison"]
    branch = None
    if "--branch" in argv:
        i = argv.index("--branch")
        branch = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) != 3:
        die("usage: fenced-env <board> <task> <profile> [--branch B] [--poison]")
    board, task, profile = argv
    base = dict(os.environ)
    granted = granted_env(board, task, profile, branch)
    from agent.delegation_context import KANBAN_ENV_KEYS, delegated_child_subprocess_env
    fenced = delegated_child_subprocess_env(granted)
    if "HERMES_DELEGATED_CHILD_CONTEXT" not in fenced:
        die("the installed Hermes did not fence a granted environment")
    if poison:
        for k in KANBAN_ENV_KEYS:
            fenced[k] = {"HERMES_KANBAN_TASK": "t_poison00", "HERMES_KANBAN_RUN_ID": "999",
                         "HERMES_KANBAN_CLAIM_LOCK": "poison:0:0"}.get(k, "1")
    for k in sorted(fenced):
        if base.get(k) != fenced[k]:
            print(f"export {k}={shlex.quote(fenced[k])}")
    for k in sorted(base):
        if k not in fenced:
            print(f"unset {k}")


def _call(tool, args):
    from tools.registry import registry
    out = registry.dispatch(tool, args)
    if isinstance(out, str):
        try:
            out = json.loads(out)
        except ValueError:
            out = {"error": out}
    return out


def cmd_perform(argv):
    if len(argv) != 4:
        die("usage: perform <board> <task> <profile> <envelope.json>")
    board, task, profile, path = argv
    try:
        envelope = json.load(open(path))
    except (OSError, ValueError) as e:
        die(f"cannot read the envelope {path}: {e}")
    granted = granted_env(board, task, profile)
    os.environ.clear()
    os.environ.update(granted)                 # the driver's process: granted, unfenced
    import tools.kanban_tools                  # noqa: F401  (registers the handlers)
    terminate, on_error = envelope.get("terminate"), envelope.get("on_error")
    if not (isinstance(terminate, dict) and terminate.get("tool")):
        die("the envelope names no terminate call")
    res = _call(terminate["tool"], terminate.get("args") or {})
    print(json.dumps({"call": "terminate", "tool": terminate["tool"], "result": res}))
    if "error" not in res:
        return 0
    if not (isinstance(on_error, dict) and on_error.get("tool")):
        return 11
    res2 = _call(on_error["tool"], on_error.get("args") or {})
    print(json.dumps({"call": "on_error", "tool": on_error["tool"], "result": res2}))
    return 10 if "error" not in res2 else 11


def cmd_claim_review(argv):
    if len(argv) != 2:
        die("usage: claim-review <board> <task>")
    isolated_home()
    board, task = argv
    os.environ["HERMES_KANBAN_BOARD"] = board
    from hermes_cli import kanban_db as kb, kanban_db_connect as kbc
    with kbc.connect_closing() as conn:
        return 0 if kb.claim_review_task(conn, task) is not None else 1


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("fenced-env", "perform", "claim-review"):
        die(__doc__.split("\n\n")[0] + " — see the module docstring")
    cmd, rest = sys.argv[1], sys.argv[2:]
    isolated_home()
    sys.exit({"fenced-env": cmd_fenced_env, "perform": cmd_perform,
              "claim-review": cmd_claim_review}[cmd](rest) or 0)


if __name__ == "__main__":
    main()
