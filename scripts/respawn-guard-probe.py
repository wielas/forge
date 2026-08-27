"""Assert the five contracts of Hermes' `check_respawn_guard`, behaviourally.

WHAT THIS TOUCHES: a throwaway directory under $TMPDIR and nothing else. It
never reads, opens, copies or writes ~/.hermes/kanban.db or any other live
board — HERMES_HOME is redirected into that temp dir BEFORE `hermes_cli` is
imported, the three env vars that can override the redirect are unset, the
board path is passed explicitly to init_db()/connect() rather than resolved,
and the resolved path is asserted to live under the temp dir before a single
row is written. The temp dir is removed on every exit path. This is why
scripts/preflight.sh can run it and stay READ-ONLY BY DESIGN (preflight.sh
header): the assertion is not "we were careful", it is checked at line
_assert_under_tmp() below and turns into exit 2 if it does not hold.

WHY IT EXISTS: `hermes update` falls back to `git reset --hard origin/<branch>`
when history has diverged (hermes_cli/update_cmd.py, the ff-only branch), which
destroyed the locally carried commit `fix(kanban): let unblock supersede prior
PR guard` during the 0.19.0 -> 0.20.4 upgrade. Nothing announced the loss: the
0.20.4 version banner no longer prints a carried-commit count. Forge has already
been bitten by the underlying bug in production — docs/audit-forgeboard-
2026-07-30.md records `respawn_guarded: active_pr after explicit unblock`.

WHY BEHAVIOUR, NOT A SHA: pinning the commit hash proves nothing about what the
code does and goes stale on every re-cherry-pick. These five assertions hold for
any implementation that behaves correctly, and fail for any that does not —
including a fresh upstream release that never carried the patch at all.

The five contracts:
  1. active_pr fires when a PR-evidence comment is the newest thing on the task.
  2. CARRIED FIX: an explicit re-queue event (`unblocked`) AFTER that comment
     supersedes it, so the guard clears. Upstream applies exactly this
     requeue-supersedes rule to its own `recent_success` step and never to
     `active_pr`; contract 2 is the gap upstream's own code argues against.
  3. UPSTREAM: without a re-queue, the ready lane still defers on active_pr.
  4. UPSTREAM: the review lane bypasses active_pr entirely — a fresh PR comment
     is the *precondition* of a review handoff, not duplicate-work evidence.
  5. CARRIED FIX, NARROWED: an AUTOMATIC re-queue (`reclaimed`, and likewise
     `promoted` from recompute_ready) does NOT clear the guard. Only explicit
     operator/reviewer continuations do. A crash reclaim that cleared it would
     respawn a worker while the prior PR is still open — the duplicate PR the
     rule exists to prevent. This bounds contract 2 from the other side: 2
     alone is satisfied by a patch that clears on everything.

Contracts 3 and 4 are upstream's behaviour, not the patch's. They are asserted
here because a regression in either is equally worth catching, and because a
probe that only checks the local patch cannot tell "the patch is gone" from
"the whole function changed shape underneath it".

EXIT CODES — deliberately three, following the precedent CLAUDE.md sets for
scripts/prejudge.sh ("exit 1 = block, exit 2 = the gate failed to run. These are
deliberately different; do not conflate them"):

  0  every contract evaluated and held.
  1  the probe ran and a contract was VIOLATED. The guard is wrong; on this
     host that almost certainly means the carried patch is gone again.
  2  the probe COULD NOT RUN and no contract was evaluated: hermes_cli is not
     importable, init_db failed, the board path did not resolve under $TMPDIR,
     the schema no longer has the columns these fixtures write, or
     check_respawn_guard no longer takes the arguments it is called with. This
     is not a pass. Nothing was checked.

The discriminator is "did the assertion evaluate?", not "did something throw?".
Every step that builds the fixture runs inside one try/except; anything raising
out of it means no verdict was reached, which is exit 2. Only the four
comparisons themselves can produce exit 1.

Run it with the interpreter that can import hermes_cli (the Hermes venv's
python3). There is deliberately no shebang and no exec bit: the one supported
entry path is `<that python> scripts/respawn-guard-probe.py`, so it cannot be
started under an interpreter that would fail the import and look like a
different kind of failure.
"""

import os
import pathlib
import shutil
import sys
import tempfile
import time
import traceback

EXIT_OK = 0
EXIT_CONTRACT_VIOLATED = 1
EXIT_CANNOT_RUN = 2

# Every one of these overrides `HERMES_HOME` in kanban_db.kanban_db_path() /
# workspaces_root() / get_current_board(), and the Hermes dispatcher INJECTS
# HERMES_KANBAN_DB into worker environments. Inheriting one would point this
# probe's writes at the live board. Redirection is not enough on its own —
# the overrides have to go too.
_ENV_OVERRIDES = (
    "HERMES_KANBAN_DB",
    "HERMES_KANBAN_WORKSPACES_ROOT",
    "HERMES_KANBAN_BOARD",
)


def _cannot_run(reason, exc=None):
    print("PROBE-ERROR  " + reason)
    if exc is not None:
        for line in traceback.format_exception_only(type(exc), exc):
            print("             " + line.rstrip())
    print()
    print("RESULT: COULD NOT RUN — no contract was evaluated (exit 2)")
    return EXIT_CANNOT_RUN


def _run(tmp):
    home = os.path.join(tmp, ".hermes")
    os.makedirs(home)
    os.environ["HERMES_HOME"] = home
    for var in _ENV_OVERRIDES:
        os.environ.pop(var, None)

    try:
        from hermes_cli import kanban_db as kb
    except Exception as exc:  # noqa: BLE001 — any import failure is "cannot run"
        return _cannot_run(
            "cannot import hermes_cli. Run this under the Hermes venv's python3 "
            "(resolved from the `hermes` shim's exec line).",
            exc,
        )

    fails = []

    def check(name, cond):
        print(("PASS  " if cond else "FAIL  ") + name)
        if not cond:
            fails.append(name)

    try:
        # Pass the path explicitly rather than letting kanban_db resolve one.
        # Resolution reads env and on-disk board state; passing it removes the
        # question entirely, and the assert below proves the answer anyway.
        db_path = os.path.join(home, "kanban.db")
        used = kb.init_db(pathlib.Path(db_path))
        resolved = os.path.realpath(str(used))
        if not resolved.startswith(os.path.realpath(tmp) + os.sep):
            return _cannot_run(
                "REFUSING TO WRITE: the board resolved to %s, which is outside "
                "the temp dir %s. This probe must never touch a live board."
                % (resolved, tmp)
            )

        conn = kb.connect(used)
        try:
            now = int(time.time())

            # Contracts 1 and 2 — the carried fix. A dependency worker records
            # the unmerged parent PR as block evidence; an operator then merges
            # that PR and unblocks the same card. Before the fix the guard read
            # the stale PR comment and refused the respawn forever.
            t = kb.create_task(conn, title="dependency-retry", assignee="alice")
            conn.execute(
                "INSERT INTO task_comments (task_id, author, body, created_at) "
                "VALUES (?, 'worker', "
                "'Parent open: https://github.com/example/project/pull/42', ?)",
                (t, now - 10),
            )
            before = kb.check_respawn_guard(conn, t)
            conn.execute(
                "INSERT INTO task_events (task_id, kind, created_at) "
                "VALUES (?, 'unblocked', ?)",
                (t, now),
            )
            after = kb.check_respawn_guard(conn, t)

            # Contracts 3 and 4 — upstream's own behaviour, no re-queue event.
            t2 = kb.create_task(conn, title="already PRed", assignee="worker")
            kb.add_comment(
                conn,
                t2,
                author="worker",
                body="Opened https://github.com/example/repo/pull/123 for review.",
            )
            ready_lane = kb.check_respawn_guard(conn, t2)
            review_lane = kb.check_respawn_guard(conn, t2, lane="review")

            # Contract 5 — an AUTOMATIC re-queue after the PR comment must NOT
            # clear the guard. The event must land AFTER the comment: on a task
            # with no PR evidence this would pass under any implementation and
            # assert nothing at all.
            t3 = kb.create_task(conn, title="auto-reclaimed", assignee="worker")
            kb.add_comment(
                conn,
                t3,
                author="worker",
                body="Opened https://github.com/example/repo/pull/124 for review.",
            )
            conn.execute(
                "INSERT INTO task_events (task_id, kind, created_at) "
                "VALUES (?, 'reclaimed', ?)",
                (t3, now),
            )
            after_auto = kb.check_respawn_guard(conn, t3)
        finally:
            conn.close()
    except Exception as exc:  # noqa: BLE001 — fixture build failed: no verdict
        return _cannot_run(
            "the fixture could not be built or check_respawn_guard could not be "
            "called as expected — schema or signature has changed. NOTHING was "
            "verified.",
            exc,
        )

    # Only past this point can a verdict exist. Everything below is comparison.
    check("active_pr fires before unblock", before == "active_pr")
    check("CARRIED FIX: unblock supersedes active_pr", after is None)
    check("UPSTREAM: ready lane still defers on active_pr", ready_lane == "active_pr")
    check("UPSTREAM: review lane bypasses active_pr", review_lane is None)
    check("CARRIED FIX NARROWED: automatic reclaim does NOT clear active_pr",
          after_auto == "active_pr")

    print()
    if not fails:
        print("RESULT: ALL GREEN — 5/5 contracts hold (exit 0)")
        return EXIT_OK
    print("RESULT: %d of 5 contracts VIOLATED (exit 1): %s" % (len(fails), ", ".join(fails)))
    if "CARRIED FIX: unblock supersedes active_pr" in fails:
        print("        The carried commit 'fix(kanban): let unblock supersede prior")
        print("        PR guard' is most likely gone from ~/.hermes/hermes-agent.")
        print("        `hermes update` resets --hard on divergence and 0.20.4 no")
        print("        longer prints a carried-commit count, so nothing announces it.")
    return EXIT_CONTRACT_VIOLATED


def main():
    try:
        tmp = tempfile.mkdtemp(prefix="forge-respawn-guard-")
    except Exception as exc:  # noqa: BLE001
        return _cannot_run("cannot create a temp dir under $TMPDIR", exc)
    try:
        return _run(tmp)
    except Exception as exc:  # noqa: BLE001 — crashed before reaching a verdict
        # Belt for the parts of _run() that sit outside its own try (the
        # makedirs, the environment edits). Without this they would escape,
        # and CPython would exit 1 — the code that means "a contract is
        # violated" — for something that evaluated no contract at all.
        return _cannot_run("the probe crashed before reaching a verdict", exc)
    finally:
        # The seed version of this probe leaked its temp dir on every run.
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
