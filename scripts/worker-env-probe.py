"""Assert that a routed Hermes worker's `claude` gets the root OAuth token, with Hermes' OWN code.

WHY IT EXISTS. Rehearsal 5 of run A (2026-10-29) failed at the verifier's judge call: `claude -p`
reported "Failed to authenticate: OAuth session expired and could not be refreshed", because
CLAUDE_CODE_OAUTH_TOKEN was absent from its environment and the CLI fell back to an expired
keychain login. Every check that preceded it passed. T1 (docs/run-a.md, amendment 4) built its own
stripped environment by hand; T2 accepted a profile `.env` with no token line as "inherits the
root's" — and for a ROUTED profile that is false: when the dispatcher spawns the worker
(hermes_cli/kanban_db_dispatch.py, `_spawn_worker`) it calls `strip_launch_profile_env`
(tools/environments/local.py), which deletes every name the launch ~/.hermes/.env defines unless
agent/secret_scope.py lists it as global — and this one is not listed. The worker then reloads only
its own profile `.env`, which has no token (and must not: a copy there goes stale).

WHAT THIS DOES, per profile (forge-verifier, forge-prejudge, forge-codex-lane, whichever exist):
  1. Starts from the launch environment the gateway has: load_hermes_dotenv() on ~/.hermes.
  2. Builds the worker's environment exactly as `_spawn_worker` does — build_subprocess_env inside
     _worker_profile_scope, HERMES_HOME pointed at the profile, strip_launch_profile_env — then
     overlays the profile's own `.env`, which is all the worker reloads.
  3. Runs a stub `claude` in that environment TWICE: bare (the control, which records the defect),
     and through scripts/claude-token.sh (the repair). The stub prints only the sha256 of what it
     received, to this process; the comparison is here, and neither token nor hash is ever printed.

PASS means: through the helper, the stub received exactly the root token. The bare control
is reported as well. If the control already receives the token, Hermes no longer strips it and the
scenario is not reproduced; that is said, and is not a failure (the helper is still required to
deliver).

WHAT THIS TOUCHES: reads ~/.hermes/.env and the profile `.env` files, writes nothing under
~/.hermes (the stub lives in a temp dir that is removed on every exit path), spawns two `bash`
processes per profile and no model. It spends no tokens.

EXIT CODES (the precedent scripts/respawn-guard-probe.py sets; "cannot run" is not a pass):
  0  every profile received the root token through the helper.
  1  the probe ran and at least one profile did NOT receive it. The repair is broken or bypassed.
  2  the probe COULD NOT RUN: a Hermes import or function this code depends on moved, the helper
     is missing, or forge-verifier does not exist. Nothing was verified.
  3  there is no CLAUDE_CODE_OAUTH_TOKEN in the root ~/.hermes/.env, so there is nothing to deliver.

Run it with the Hermes venv's python3, in an environment with nothing but HOME and PATH (the
preflight does: `env -i`), so the launch environment is the one this script builds and not the
caller's. Usage:  <python3> -I scripts/worker-env-probe.py <path to scripts/claude-token.sh>
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import traceback

EXIT_OK, EXIT_NOT_DELIVERED, EXIT_CANNOT_RUN, EXIT_NO_TOKEN = 0, 1, 2, 3
KEY = "CLAUDE_CODE_OAUTH_TOKEN"
PROFILES = ("forge-verifier", "forge-prejudge", "forge-codex-lane")
REQUIRED = "forge-verifier"


def cannot_run(why):
    print(f"CANNOT RUN: {why}")
    print("RESULT: the probe could not run; nothing was verified")
    return EXIT_CANNOT_RUN


def sha(value):
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()


STUB = """#!{python}
import hashlib, os, sys
sys.stdin.read()
t = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
print("absent" if not t else hashlib.sha256(t.encode("utf-8", "surrogateescape")).hexdigest())
"""


def run_stub(env, helper, stubdir, through_helper):
    """What the stub `claude` received: 'absent' or a sha256, never a value."""
    env = dict(env)
    env["PATH"] = stubdir + os.pathsep + env.get("PATH", "")
    script = (". \"$1\"; " if through_helper else "") + "printf x | claude -p hello"
    proc = subprocess.run(
        ["/bin/bash", "-c", script, "_", helper],
        env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
    )
    lines = [l for l in proc.stdout.splitlines() if l.strip()]
    return lines[-1].strip() if proc.returncode == 0 and lines else f"rc{proc.returncode}"


def main():
    if len(sys.argv) != 2:
        return cannot_run("usage: worker-env-probe.py <path to scripts/claude-token.sh>")
    helper = os.path.abspath(sys.argv[1])
    if not os.path.isfile(helper):
        return cannot_run(f"the helper is missing: {helper}")
    home = os.path.join(os.path.expanduser("~"), ".hermes")
    if not os.path.isdir(os.path.join(home, "profiles", REQUIRED)):
        return cannot_run(f"no {REQUIRED} profile under {home}/profiles")
    os.environ["HERMES_HOME"] = home
    sys.path.insert(0, os.path.join(home, "hermes-agent"))
    try:
        from hermes_cli.env_loader import load_hermes_dotenv
        from hermes_cli.profiles import normalize_profile_name, resolve_profile_env
        from agent.secret_scope import is_multiplex_active, load_env_file
        from tools.environments.local import _is_routed_home, build_subprocess_env, strip_launch_profile_env
        from hermes_cli.kanban_db_dispatch import _worker_profile_scope
    except Exception as exc:   # ImportError, or a module that no longer exports a name
        return cannot_run(f"Hermes moved something this probe imports: {type(exc).__name__}: {exc}")

    try:
        root_env = load_env_file(__import__("pathlib").Path(home) / ".env")
        want = root_env.get(KEY, "")
        if not want:
            print(f"NO TOKEN: {KEY} is not defined in {home}/.env")
            print("RESULT: nothing to deliver")
            return EXIT_NO_TOKEN
        load_hermes_dotenv(hermes_home=home)
        launch_has = bool(os.environ.get(KEY))
    except Exception as exc:
        return cannot_run(f"loading the launch environment failed: {type(exc).__name__}: {exc}")

    stubdir = tempfile.mkdtemp(prefix="forge-worker-env-")
    bad, seen, lines = 0, 0, []
    try:
        stub = os.path.join(stubdir, "claude")
        with open(stub, "w") as fh:
            fh.write(STUB.format(python=sys.executable))
        os.chmod(stub, 0o755)
        for prof in PROFILES:
            if not os.path.isdir(os.path.join(home, "profiles", prof)):
                lines.append(f"{prof}: no such profile here, skipped")
                continue
            try:
                ph = resolve_profile_env(normalize_profile_name(prof))
                routed = bool(ph) and _is_routed_home(ph)
                with _worker_profile_scope(ph, bind_home=False):
                    env = build_subprocess_env(scrub_secrets=is_multiplex_active() or routed,
                                               inherit_profile_home=True)
                before = KEY in env
                env["HERMES_HOME"] = ph
                strip_launch_profile_env(env, ph)
                after = KEY in env
                # the worker reloads its own profile .env, and only that
                from pathlib import Path
                env.update({k: v for k, v in load_env_file(Path(ph) / ".env").items()})
            except Exception as exc:
                return cannot_run(f"building {prof}'s worker environment failed: {type(exc).__name__}: {exc}")
            seen += 1
            control = run_stub(env, helper, stubdir, through_helper=False)
            via = run_stub(env, helper, stubdir, through_helper=True)
            got_control = "delivered" if control == sha(want) else ("absent" if control == "absent" else "OTHER-VALUE")
            if via == sha(want):
                verdict = "delivered"
            elif via == "absent":
                verdict, bad = "ABSENT", bad + 1
            else:
                verdict, bad = ("a DIFFERENT token" if len(via) == 64 else f"failed ({via})"), bad + 1
            lines.append(f"{prof}: routed={routed} launch_had_token={before} after_strip={after} "
                         f"bare_claude={got_control} through_helper={verdict}")
    finally:
        shutil.rmtree(stubdir, ignore_errors=True)

    for l in lines:
        print(l)
    if not launch_has:
        print("NOTE: load_hermes_dotenv did not publish the token into the launch environment; "
              "the strip was not exercised.")
    if seen == 0:
        return cannot_run("no profile was exercised")
    if bad:
        print(f"RESULT: {bad} of {seen} profiles did NOT receive the root token through the helper")
        return EXIT_NOT_DELIVERED
    print(f"RESULT: ALL GREEN ({seen} profiles receive the root token through the helper)")
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:
        # a traceback is data about the code, never about the token (no value is held in a frame we print)
        print("CANNOT RUN: the probe raised:")
        print(traceback.format_exc(limit=3).splitlines()[-1])
        sys.exit(EXIT_CANNOT_RUN)
