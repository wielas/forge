#!/usr/bin/env python3
"""Did Codex commit inside its sandbox, or only through an escalated retry?

codex-cli 0.164.0 stopped letting a `workspace-write` sandbox that was granted
only the git common dir write a linked worktree's own gitdir, so `git add` died
on `index.lock': Operation not permitted`. Rehearsals 1-6 of run A hit that
denial every time and still committed, because ~/.codex/config.toml carried
`approvals_reviewer = "auto_review"`, which approved an escalated retry
(`sandbox_permissions: "require_escalated"`). The result looked identical to a
run that never needed the escalation. This reads what the lane's Codex actually
did, out of the rollouts it writes under ~/.codex/sessions.

It finds the rollouts for ONE worktree by cwd (session_meta.payload.cwd, real
paths on both sides) inside a time window, and reports, per rollout:
  denial      lines carrying `index.lock': Operation not permitted`
  escalation  tool calls whose arguments carry sandbox_permissions
              "require_escalated", and a guardian_review sub-thread (the
              auto-review session that approves one)
Only tool CALLS are searched for the escalation: every rollout also carries the
tool's schema, which names `require_escalated` in prose, so a plain grep for the
word is true of a clean run too.

Exit: 0  at least one rollout matched and none shows a denial or an escalation
      1  a matched rollout shows one (a finding)
      2  no rollout matched, or the inputs cannot be read. This is NOT a pass:
         a check that found nothing to read has verified nothing.

With --expect-root (repeatable) it also reads the sandbox policy Codex recorded
for each turn (turn_context.payload.sandbox_policy.writable_roots) and fails
when a root the runner meant to grant never arrived. That is the end-to-end
proof of codex-run.sh's argv: nothing free proves that `codex exec` maps two
`--add-dir` flags to two writable roots (`codex sandbox`, which preflight uses,
takes the `-c` form instead). No turn_context at all is exit 2: the grant was
not observed.

With --expect-approval it reads the approval policy the same turn_context
records (payload.approval_policy) and fails when any turn of the lane's own
rollouts ran under another one. codex-run.sh passes `-c approval_policy="never"`
so a sandbox refusal is a plain failure and not an auto-approved escalation;
rehearsal 6's rollout recorded `on-request`. `codex debug prompt-input` shows
that `-c` reaches the core config, but only the rollout shows that `codex exec`
did not override it. A turn_context with no approval_policy is exit 2, as for
the roots: the pin was not observed. The auto-review sub-thread's own turns are
not the lane's and are not read.

Prints counts and paths only, never rollout content.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys

DENIAL = "index.lock': Operation not permitted"
ESCALATION = re.compile(r"sandbox_permissions\W{1,8}require_escalated")


def parse_ts(value):
    try:
        text = str(value).replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(text).timestamp()
    except (ValueError, TypeError):
        return None


def first_meta(path):
    try:
        with open(path, "r", errors="replace") as handle:
            line = handle.readline()
        record = json.loads(line)
    except (OSError, ValueError):
        return None
    if record.get("type") != "session_meta":
        return None
    payload = record.get("payload")
    return payload if isinstance(payload, dict) else None


def scan(path):
    denial = escalation = 0
    roots = set()
    policies = set()
    with open(path, "r", errors="replace") as handle:
        for number, line in enumerate(handle):
            if number == 0:
                continue  # session_meta: base instructions, the schema
            if DENIAL in line:
                denial += 1
            if '"turn_context"' in line:
                try:
                    tc = json.loads(line).get("payload") or {}
                    policy = tc.get("sandbox_policy") or {}
                    if tc.get("approval_policy") is not None:
                        policies.add(json.dumps(tc["approval_policy"]).strip('"'))
                    for root in policy.get("writable_roots") or []:
                        roots.add(os.path.realpath(str(root)))
                except (ValueError, AttributeError):
                    pass
            if "require_escalated" not in line:
                continue
            try:
                payload = json.loads(line).get("payload") or {}
            except ValueError:
                continue
            kind = str(payload.get("type", ""))
            if kind.endswith("_call") and ESCALATION.search(json.dumps(payload)):
                escalation += 1
    return denial, escalation, roots, policies


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cwd", required=True, help="the worktree the lane's Codex ran in")
    ap.add_argument("--since", type=int, required=True, help="epoch seconds: the lane run's start")
    ap.add_argument("--until", type=int, default=None, help="epoch seconds: the lane run's end")
    ap.add_argument("--expect-root", action="append", default=[],
                    help="a directory the sandbox must have been granted (repeatable)")
    ap.add_argument("--expect-approval", default=None, metavar="POLICY",
                    help="the approval policy every turn of the lane's Codex must have run under")
    ap.add_argument("--sessions", default=None,
                    help="rollout root [${CODEX_HOME:-~/.codex}/sessions]")
    args = ap.parse_args()

    root = args.sessions or os.path.join(
        os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "sessions")
    if not os.path.isdir(root):
        print("codex-rollout-check: %s is not a directory" % root)
        return 2
    want = os.path.realpath(args.cwd)
    lo = args.since - 120
    hi = (args.until + 600) if args.until else None

    matched = []
    for base, _dirs, files in os.walk(root):
        for name in sorted(files):
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(base, name)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if mtime < lo:
                continue
            meta = first_meta(path)
            if not meta or not meta.get("cwd"):
                continue
            if os.path.realpath(str(meta["cwd"])) != want:
                continue
            started = parse_ts(meta.get("timestamp")) or mtime
            if started < lo or (hi is not None and started > hi):
                continue
            matched.append((path, meta))

    if not matched:
        print("codex-rollout-check: NO rollout under %s has cwd %s in the window — nothing was verified" % (root, want))
        return 2

    findings = 0
    granted = set()
    approvals = set()
    for path, meta in sorted(matched):
        denial, escalation, roots, policies = scan(path)
        guardian = 1 if meta.get("thread_source") == "guardian_review" else 0
        if not guardian:
            granted |= roots
            approvals |= policies
        bad = denial or escalation or guardian
        findings += 1 if bad else 0
        print("%s %s denial=%d escalation=%d guardian_review=%d (codex %s)" % (
            "FINDING" if bad else "clean  ", os.path.basename(path),
            denial, escalation, guardian, meta.get("cli_version", "?")))
    print("codex-rollout-check: %d rollout(s) for %s, %d with a denial or an escalation" % (
        len(matched), want, findings))
    missing = []
    if args.expect_root:
        print("writable_roots recorded by the lane's Codex: %s" % (sorted(granted) or "none"))
        if not granted:
            print("codex-rollout-check: no turn_context carried a sandbox policy — the grant was not observed")
            return 2
        missing = [r for r in args.expect_root if os.path.realpath(r) not in granted]
        for root in missing:
            print("FINDING expected writable root never granted: %s" % root)
    wrong = []
    if args.expect_approval is not None:
        print("approval_policy recorded by the lane's Codex: %s" % (sorted(approvals) or "none"))
        if not approvals:
            print("codex-rollout-check: no turn_context carried an approval_policy — the pin was not observed")
            return 2
        wrong = sorted(a for a in approvals if a != args.expect_approval)
        for policy in wrong:
            print("FINDING approval_policy %s was recorded, expected %s" % (policy, args.expect_approval))
    return 1 if findings or missing or wrong else 0


if __name__ == "__main__":
    sys.exit(main())
