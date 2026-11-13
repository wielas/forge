#!/usr/bin/env python3
"""forge board-sync planner: the diff, the order, the release checks and the read-backs.

hermes/board-sync.sh is the program; this is the part of it that is arithmetic. It reads
a SNAPSHOT of a Hermes board (a copy made by scripts/board-snapshot.sh: a board is WAL
and is never opened in place, never mode=ro) and the units hermes/board-sync.sh derived
from docs/chunks/graph.json. It never calls Hermes and never writes a board.

  plan      the diff and the ordered steps       -> a JSON plan file
  render    the plan as the report an operator reads, decision first
  precheck  one step against a FRESH snapshot: still safe? its argv, ids resolved
  postcheck one step's effect: the board after it against the board before it

Three kernel facts decide the order and the checks (Hermes 0.21.5, hermes_cli/kanban_db.py):
  - `create` is atomic with its --parent edges and computes the status itself: todo when
    any parent is not `done`, ready otherwise. It treats `archived` as not-done, but
    recompute_ready treats archived as done, so a card whose parents are all done or
    archived is dispatchable at once.
  - `unlink` runs recompute_ready on the whole board: a todo card left with no open
    parent is `ready` before the call returns, and the dispatcher can claim it in 60 s.
  - `link` only ever DEMOTES a ready child; it never promotes anything.
So every create names all its parents, links come before unlinks, and an unlink (or a
create) that would leave a card dispatchable is a step the plan refuses unless the
operator said --allow-release.

Exit: 0 done, 1 a step refused or a surprise (precheck/postcheck), 2 unreadable input.
"""
import argparse
import difflib
import json
import re
import shlex
import sqlite3
import sys

TERMINAL = ("done", "archived")
NOT_STARTED = ("todo", "blocked", "triage", "scheduled")
UNIT_KEY = re.compile(r"^(CHUNK|GATE)-[A-Za-z0-9][A-Za-z0-9._-]*$")
BODY_PLACEHOLDER = "--body=@FILE:"


class Unreadable(Exception):
    pass


def norm(name):
    return (name or "").strip().lower() or None


def read_body(path):
    """`$(cat file)`: what bootstrap passes as --body. Trailing newlines go, NULs go."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        raise Unreadable("cannot read %s: %s" % (path, exc))
    return raw.decode("utf-8", "surrogateescape").replace("\0", "").rstrip("\n")


class Board(object):
    """One snapshot: cards, edges, and which blocked cards are sticky."""

    def __init__(self, path):
        try:
            db = sqlite3.connect(path)
            db.text_factory = lambda b: b.decode("utf-8", "surrogateescape")
            cols = set(r[1] for r in db.execute("PRAGMA table_info(tasks)"))
            need = set(["id", "title", "body", "assignee", "status", "idempotency_key", "branch_name"])
            if not need <= cols:
                raise Unreadable("the board has no tasks table with %s" % ", ".join(sorted(need - cols)))
            kind = "block_kind" if "block_kind" in cols else "NULL"
            created = "created_at" if "created_at" in cols else "0"
            workspace = "COALESCE(workspace_kind, '')" if "workspace_kind" in cols else "''"
            self.cards = {}
            for r in db.execute(
                "SELECT id, title, body, assignee, status, idempotency_key, branch_name, %s, %s, %s FROM tasks"
                % (kind, created, workspace)
            ):
                self.cards[r[0]] = {
                    "id": r[0], "title": r[1] or "", "body": r[2] or "", "assignee": r[3],
                    "status": r[4], "key": r[5], "branch": r[6], "block_kind": r[7],
                    "created": r[8] or 0, "workspace": r[9],
                }
            self.links = set((r[0], r[1]) for r in db.execute("SELECT parent_id, child_id FROM task_links"))
            self.sticky_ids = set()
            try:
                for cid in [c["id"] for c in self.cards.values() if c["status"] == "blocked"]:
                    row = db.execute(
                        "SELECT kind FROM task_events WHERE task_id = ? AND kind IN ('blocked', 'unblocked') "
                        "ORDER BY id DESC LIMIT 1", (cid,)).fetchone()
                    if row and row[0] == "blocked":
                        self.sticky_ids.add(cid)
            except sqlite3.Error:
                pass
            db.close()
        except sqlite3.Error as exc:
            raise Unreadable("cannot read the board snapshot %s: %s" % (path, exc))
        self.by_key = {}
        for c in self.cards.values():
            if c["key"]:
                self.by_key.setdefault(c["key"], []).append(c)

    def unit_card(self, board, uid):
        """The card a plan unit lives on: the one live card with its key, else the newest archived one.
        An archived card still counts as present: create ignores archived keys and would duplicate it."""
        cands = self.by_key.get("%s-%s" % (board, uid), [])
        live = [c for c in cands if c["status"] != "archived"]
        if len(live) > 1:
            raise Unreadable("%d live cards carry the key %s-%s (%s): the board is ambiguous, repair it first"
                             % (len(live), board, uid, ", ".join(sorted(c["id"] for c in live))))
        if live:
            return live[0]
        if cands:
            return sorted(cands, key=lambda c: (c["created"], c["id"]))[-1]
        return None

    def parents(self, cid):
        return sorted(p for (p, c) in self.links if c == cid)

    def editable(self, c):
        """Not started: todo, ready, or blocked on the bootstrap's own hold (unassigned, needs_input or untyped)."""
        if c["status"] in ("todo", "ready"):
            return True
        return c["status"] == "blocked" and c["assignee"] is None and c["block_kind"] in (None, "needs_input")


def group_of(board, c):
    if c["status"] in TERMINAL:
        return "done"
    return "editable" if board.editable(c) else "inflight"


def unit_name(board_slug, c):
    key = c.get("key") or ""
    pre = board_slug + "-"
    return key[len(pre):] if key.startswith(pre) else c["id"]


# ---------------------------------------------------------------------------- plan

def make_plan(units, snap, board_slug, allow_release):
    board = Board(snap)
    uids = [u["id"] for u in units]
    by_id = dict((u["id"], u) for u in units)
    bodies = dict((u["id"], read_body("docs/chunks/%s.md" % u["id"])) for u in units)
    unit_cards = dict((uid, board.unit_card(board_slug, uid)) for uid in uids)
    card_unit = dict((c["id"], uid) for uid, c in unit_cards.items() if c)
    lines = []

    def line(verdict, unit, card, detail, blocks=False):
        lines.append({"verdict": verdict, "unit": unit, "card": card["id"] if card else None,
                      "status": card["status"] if card else None, "detail": detail, "blocks": blocks})

    # --- units with no card: CREATE (lane cards) or MANUAL (a gate or an interactive chunk) ---
    missing = [uid for uid in uids if unit_cards[uid] is None]
    uncreatable = set()
    why = {}
    for uid in missing:
        if by_id[uid]["kind"] != "lane":
            uncreatable.add(uid)
            why[uid] = ("has no card, and sync does not create a %s: holding it takes `block` and `assign`, which sync never runs. "
                        "Create it the way hermes/board-bootstrap.sh does (create on forge-operator-handoff, block --kind needs_input, "
                        "assign none, then link each parent), then run sync again"
                        % ("gate" if by_id[uid]["kind"] == "gate" else "claude-interactive chunk"))
    changed = True
    while changed:
        changed = False
        for uid in missing:
            if uid in uncreatable:
                continue
            bad = [d for d in by_id[uid]["deps"] if d in uncreatable]
            if bad:
                uncreatable.add(uid)
                why[uid] = "has no card, and its parent %s has none that sync can create; create %s first" % (bad[0], bad[0])
                changed = True
    for uid in missing:
        if uid in uncreatable:
            line("MANUAL", uid, None, why[uid], blocks=True)

    # creation order: a unit goes in once every parent has a card or has been placed
    placed = []
    todo = [uid for uid in missing if uid not in uncreatable]
    while todo:
        progressed = False
        for uid in list(todo):
            if all(unit_cards.get(d) is not None or d in placed for d in by_id[uid]["deps"]):
                placed.append(uid)
                todo.remove(uid)
                progressed = True
        if not progressed:
            raise Unreadable("the graph has a cycle among %s" % ", ".join(todo))

    def ref(uid):
        c = unit_cards.get(uid)
        return "card:%s" % c["id"] if c else "unit:%s" % uid

    def rid(uid):
        c = unit_cards.get(uid)
        return c["id"] if c else "unit:%s" % uid

    # --- units with a card ---
    suffix_suspects = []
    add_edges, remove_edges, edits = [], [], []
    for uid in uids:
        c = unit_cards[uid]
        if c is None:
            continue
        u = by_id[uid]
        grp = group_of(board, c)
        found = False
        if c["body"] != bodies[uid]:
            nlines = sum(1 for d in difflib.ndiff(c["body"].splitlines(), bodies[uid].splitlines()) if d[:1] in ("+", "-"))
            what = "the card body differs from docs/chunks/%s.md (%d line(s) differ)" % (uid, nlines)
            if grp == "done":
                line("STALE-DONE", uid, c, "%s; a %s card is never edited" % (what, c["status"]))
            elif grp == "inflight":
                line("IN-FLIGHT", uid, c, "%s; the card is %s, so it is left alone" % (what, c["status"]))
            else:
                line("UPDATE-BODY", uid, c, what)
                edits.append(uid)
            found = True
        if grp == "editable":
            if c["title"].strip() != u["title"].strip():
                line("MANUAL", uid, c, "the card title is '%s' and the plan's is '%s'; sync edits bodies only" % (c["title"], u["title"]))
                found = True
            want_assignee = norm(u["lane"]) if u["kind"] == "lane" else None
            if norm(c["assignee"]) != want_assignee:
                line("MANUAL", uid, c, "assigned to %s, but the plan's lane for it is %s; sync never assigns"
                     % (c["assignee"] or "nobody", u["lane"] if u["kind"] == "lane" else "claude-interactive (held, unassigned)"))
                found = True
            if u["kind"] == "lane" and u.get("expected_branch") and c["branch"] != u["expected_branch"]:
                line("MANUAL", uid, c, "the card's branch is %s, but its own title and this run's --branch-suffix name %s"
                     % (c["branch"] or "none", u["expected_branch"]))
                suffix_suspects.append(uid)
                found = True
        if not found:
            line("MATCH", uid, c, "")

        # edges into this card
        for d in u["deps"]:
            if d in uncreatable:
                continue
            dc = unit_cards.get(d)
            if dc is not None and (dc["id"], c["id"]) in board.links:
                continue
            text = "%s -> %s" % (d, uid)
            if grp == "editable":
                add_edges.append((d, uid))
            elif grp == "done":
                line("STALE-DONE", uid, c, "the plan's edge %s is not on the board; a %s card's edges are not touched" % (text, c["status"]))
            else:
                line("IN-FLIGHT", uid, c, "the plan's edge %s is not on the board; the card is %s, so it is left alone" % (text, c["status"]))
        for p in board.parents(c["id"]):
            pu = card_unit.get(p)
            if pu is None or pu in u["deps"]:
                continue
            text = "%s -> %s" % (pu, uid)
            if grp == "editable":
                remove_edges.append((pu, uid))
            elif grp == "done":
                line("STALE-DONE", uid, c, "the board's edge %s is not in the plan; a %s card's edges are not touched" % (text, c["status"]))
            else:
                line("IN-FLIGHT", uid, c, "the board's edge %s is not in the plan; the card is %s, so it is left alone" % (text, c["status"]))

    # --- orphans: a forge key the plan no longer names ---
    prefix = board_slug + "-"
    for c in sorted(board.cards.values(), key=lambda x: (x["created"], x["id"])):
        key = c["key"] or ""
        if not key.startswith(prefix) or c["status"] == "archived":
            continue
        rest = key[len(prefix):]
        if not UNIT_KEY.match(rest) or rest in by_id:
            continue
        kids = sorted(card_unit[k] for (p, k) in board.links if p == c["id"] and k in card_unit)
        line("ORPHAN", rest, c, "carries %s, which the plan no longer names%s; reported, never touched"
             % (key, (" (it is still a parent of %s)" % ", ".join(kids)) if kids else ""))

    # --- the steps, in the only order that cannot release a card early ---
    status = dict((cid, c["status"]) for cid, c in board.cards.items())
    sticky = set(board.sticky_ids)
    edges = set(board.links)
    steps = []

    def is_open(r):
        return status.get(r, "todo") not in TERMINAL

    for uid in placed:
        u = by_id[uid]
        parents = [rid(d) for d in u["deps"]]
        hazard = None
        if not any(is_open(p) for p in parents):
            hazard = ("every parent of %s is already done or archived (or it has none), so the card would be ready at once and the "
                      "dispatcher could claim it within 60 s" % uid)
        steps.append({"kind": "create", "unit": uid, "title": u["title"] or uid, "lane": u["lane"], "branch": u["branch"],
                      "parents": ["unit:" + p[len("unit:"):] if p.startswith("unit:") else "card:" + p for p in parents], "hazard": hazard})
        status["unit:%s" % uid] = "ready" if hazard else "todo"
        for p in parents:
            edges.add((p, "unit:%s" % uid))
    order = dict((uid, i) for i, uid in enumerate(uids))
    for (d, uid) in sorted(add_edges, key=lambda e: (order[e[1]], order[e[0]])):
        steps.append({"kind": "link", "parent": ref(d), "child": ref(uid), "unit": uid, "parent_unit": d, "hazard": None})
        edges.add((rid(d), rid(uid)))
    for uid in edits:
        steps.append({"kind": "edit", "unit": uid, "card": ref(uid), "hazard": None})
    for (pu, uid) in sorted(remove_edges, key=lambda e: (order[e[1]], e[0])):
        child, parent = rid(uid), rid(pu)
        hazard = None
        if status.get(child) == "todo" or (status.get(child) == "blocked" and child not in sticky):
            if not [p for (p, c) in edges if c == child and p != parent and is_open(p)]:
                hazard = ("%s would be left with no open parent, so the kernel would make it ready at once and the dispatcher "
                          "could claim it within 60 s" % uid)
        steps.append({"kind": "unlink", "parent": ref(pu), "child": ref(uid), "unit": uid, "parent_unit": pu, "hazard": hazard})
        edges.discard((parent, child))

    refusals = []
    if not allow_release:
        for i, s in enumerate(steps):
            if s.get("hazard"):
                refusals.append({"step": i, "unit": s["unit"], "reason": s["hazard"]})
    if suffix_suspects and any(s["kind"] == "create" for s in steps):
        refusals.append({"step": None, "unit": suffix_suspects[0],
                         "reason": ("an existing card's branch does not match what its own title and this run's --branch-suffix would name "
                                    "(%s), so the branch of every new card would be inconsistent with the board; pass the suffix the board "
                                    "was started with" % ", ".join(suffix_suspects))})

    # the lines go out decision-first: what apply would do, in apply's order, then what it leaves alone
    for s in steps:
        if s["kind"] == "create":
            names = []
            for p in s["parents"]:
                if p.startswith("unit:"):
                    names.append(p[len("unit:"):])
                else:
                    names.append("%s (%s)" % (card_unit.get(p[len("card:"):], "?"), p[len("card:"):]))
            line("CREATE", s["unit"], None, "no card on the board; lane %s, branch %s, parents %s%s"
                 % (s["lane"], s["branch"], ", ".join(names) or "none", "  [REFUSED without --allow-release]" if s["hazard"] else ""))
        elif s["kind"] == "link":
            line("EDGE-ADD", s["unit"], None, "%s -> %s" % (s["parent_unit"], s["unit"]))
        elif s["kind"] == "unlink":
            line("EDGE-REMOVE", s["unit"], None, "%s -> %s%s" % (s["parent_unit"], s["unit"],
                 "  [REFUSED without --allow-release]" if s["hazard"] else ""))
    rank = {"CREATE": 0, "EDGE-ADD": 1, "UPDATE-BODY": 2, "EDGE-REMOVE": 3, "MANUAL": 4, "STALE-DONE": 5,
            "IN-FLIGHT": 6, "ORPHAN": 7, "MATCH": 8}
    lines.sort(key=lambda l: rank[l["verdict"]])
    counts = {}
    for l in lines:
        counts[l["verdict"]] = counts.get(l["verdict"], 0) + 1
    return {
        "board": board_slug, "units": len(uids), "cards": len(board.cards), "lines": lines, "steps": steps,
        "refusals": refusals, "counts": counts,
        "actionable": len(steps) + len([l for l in lines if l["blocks"]]),
        "release_allowed": bool(allow_release),
    }


# ---------------------------------------------------------------------------- steps

def step_label(step):
    k = step["kind"]
    if k in ("create", "edit"):
        return "%s %s" % (k, step["unit"])
    return "%s %s -> %s" % (k, step["parent_unit"], step["unit"])


def step_argv(plan, step, resolve):
    """The arguments after `hermes kanban --board <board>`. resolve(ref) -> a card id (or a display name)."""
    k = step["kind"]
    if k == "create":
        a = ["create", "--assignee", step["lane"], BODY_PLACEHOLDER + "docs/chunks/%s.md" % step["unit"],
             "--workspace", "worktree", "--branch", step["branch"], "--max-retries", "1",
             "--idempotency-key", "%s-%s" % (plan["board"], step["unit"]), "--skill", "forge-lane"]
        for p in step["parents"]:
            a += ["--parent", resolve(p)]
        return a + ["--json", "--", step["title"]]
    if k in ("link", "unlink"):
        return [k, resolve(step["parent"]), resolve(step["child"])]
    return ["edit", resolve(step["card"]), BODY_PLACEHOLDER + "docs/chunks/%s.md" % step["unit"]]


def display(argv):
    out = []
    for a in argv:
        if a.startswith(BODY_PLACEHOLDER):
            out.append('--body="$(cat %s)"' % a[len(BODY_PLACEHOLDER):])
        elif a.startswith("<card of "):
            out.append(a)
        else:
            out.append(shlex.quote(a))
    return " ".join(out)


def render(plan):
    c = plan["counts"]
    steps = plan["steps"]
    todo = "%d CREATE, %d UPDATE-BODY, %d EDGE-ADD, %d EDGE-REMOVE" % tuple(
        c.get(k, 0) for k in ("CREATE", "UPDATE-BODY", "EDGE-ADD", "EDGE-REMOVE"))
    left = "%d STALE-DONE, %d IN-FLIGHT, %d MANUAL, %d ORPHAN" % tuple(
        c.get(k, 0) for k in ("STALE-DONE", "IN-FLIGHT", "MANUAL", "ORPHAN"))
    blocking = len([l for l in plan["lines"] if l["blocks"]])
    if plan["actionable"] == 0:
        verdict = "IN SYNC: nothing for sync to do. It leaves alone: %s" % left
    elif plan["refusals"]:
        verdict = ("DRIFT, and --apply would be REFUSED, writing nothing: %d step(s): %s. It leaves alone: %s" % (len(steps), todo, left))
    else:
        verdict = "DRIFT: %d step(s): %s; %d unit(s) sync cannot create. It leaves alone: %s" % (len(steps), todo, blocking, left)
    out = ["VERDICT  " + verdict, ""]
    for l in plan["lines"]:
        who = "%s (%s, %s)" % (l["unit"], l["card"], l["status"]) if l["card"] else l["unit"]
        out.append("%-12s %s%s" % (l["verdict"], who, ("  " + l["detail"]) if l["detail"] else ""))
    if plan["refusals"]:
        out.append("")
        for r in plan["refusals"]:
            out.append("REFUSED  %s: %s" % (r["unit"], r["reason"]))
        if any(r["step"] is not None for r in plan["refusals"]):
            out.append("         --apply writes nothing while a step is refused. If releasing that card is what you mean: --allow-release.")
    out.append("")
    if steps:
        def shown(r):
            return r[len("card:"):] if r.startswith("card:") else "<card of %s>" % r[len("unit:"):]
        out.append("Commands --apply would run, in this order (a dry run runs none of them):")
        for i, s in enumerate(steps):
            out.append("  %d. hermes kanban --board %s %s%s" % (
                i + 1, plan["board"], display(step_argv(plan, s, shown)),
                "   <- refused without --allow-release" if s.get("hazard") and not plan["release_allowed"] else ""))
    else:
        out.append("Commands --apply would run: none.")
    return "\n".join(out)


# ---------------------------------------------------------------------------- one step against a board

def resolve_in(board, board_slug, ref_):
    if ref_.startswith("card:"):
        return ref_[len("card:"):]
    c = board.unit_card(board_slug, ref_[len("unit:"):])
    return c["id"] if c else None


def hazard_now(board, child_id, parent_id):
    c = board.cards.get(child_id)
    if c is None:
        return None
    if c["status"] == "todo" or (c["status"] == "blocked" and child_id not in board.sticky_ids):
        if not [p for p in board.parents(child_id) if p != parent_id and board.cards[p]["status"] not in TERMINAL]:
            return "it would be left with no open parent, so the kernel would make it ready at once"
    return None


def precheck(plan, idx, snap, allow_release):
    step = plan["steps"][idx]
    slug = plan["board"]
    board = Board(snap)
    k = step["kind"]
    res = {"ok": True, "skip": False, "reason": "", "label": step_label(step)}

    def fail(msg):
        res["ok"], res["reason"] = False, msg
        return res

    def cid(r):
        return resolve_in(board, slug, r)

    if k == "create":
        if board.unit_card(slug, step["unit"]) is not None:
            return fail("%s already has a card on the board (someone created it since the plan was read)" % step["unit"])
        ids = [cid(p) for p in step["parents"]]
        if None in ids or any(i not in board.cards for i in ids):
            return fail("a parent of %s has no card on the board" % step["unit"])
        if not any(board.cards[i]["status"] not in TERMINAL for i in ids) and not allow_release:
            return fail("every parent of %s is now done or archived, so the card would be ready at once and the dispatcher could claim it "
                        "within 60 s; re-run with --allow-release if that is what you mean" % step["unit"])
    else:
        child = cid(step["card"] if k == "edit" else step["child"])
        if child is None or child not in board.cards:
            return fail("the card for %s is not on the board" % step["unit"])
        if not board.editable(board.cards[child]):
            return fail("%s is now %s, which sync leaves alone" % (step["unit"], board.cards[child]["status"]))
        if k != "edit":
            parent = cid(step["parent"])
            if parent is None or parent not in board.cards:
                return fail("the card for %s is not on the board" % step["parent_unit"])
            present = (parent, child) in board.links
            if k == "link" and present:
                res["skip"] = True
            if k == "unlink":
                if not present:
                    res["skip"] = True
                else:
                    why = hazard_now(board, child, parent)
                    if why and not allow_release:
                        return fail("unlinking %s -> %s: %s, and the dispatcher could claim it within 60 s; re-run with --allow-release if "
                                    "that is what you mean" % (step["parent_unit"], step["unit"], why))
    res["argv"] = step_argv(plan, step, lambda r: cid(r) or r)
    return res


def name_of(slug, c):
    return "%s (%s)" % (unit_name(slug, c), c["id"])


def postcheck(plan, idx, before_snap, after_snap):
    """None when the step did what it was meant to and nothing else; else the first surprise."""
    step = plan["steps"][idx]
    slug = plan["board"]
    before, after = Board(before_snap), Board(after_snap)
    k = step["kind"]
    # the one status move a plan can ask for: --allow-release on an unlink that leaves its child with no open parent
    release = None
    if k == "unlink" and step.get("hazard") and plan.get("release_allowed"):
        release = resolve_in(after, slug, step["child"])
    for cid_, c in before.cards.items():
        a = after.cards.get(cid_)
        if a is None:
            return "%s is gone from the board" % name_of(slug, c)
        if cid_ == release and a["status"] == "ready":
            continue
        if c["status"] in NOT_STARTED and a["status"] != c["status"]:
            return "%s moved %s -> %s, which no step of this plan is meant to do" % (name_of(slug, c), c["status"], a["status"])
        if c["status"] in NOT_STARTED and a["assignee"] != c["assignee"]:
            return "%s was assigned %s -> %s" % (name_of(slug, c), c["assignee"] or "nobody", a["assignee"] or "nobody")
    new = sorted(set(after.cards) - set(before.cards))
    want_links = set(before.links)
    if k != "create" and new:
        return "%d card(s) appeared that this step did not create: %s" % (len(new), ", ".join(new))

    def cid(r):
        return resolve_in(after, slug, r)

    if k == "create":
        if len(new) != 1:
            return ("create left %d new card(s); a create that returns an existing card means the key %s-%s was already on the board"
                    % (len(new), slug, step["unit"]))
        c = after.cards[new[0]]
        parents = [cid(p) for p in step["parents"]]
        for p in parents:
            want_links.add((p, c["id"]))
        # the kernel's own rule: todo unless every parent is `done` (an archived parent is not `done` to create)
        want_status = "ready" if all(after.cards[p]["status"] == "done" for p in parents if p in after.cards) else "todo"
        problems = []
        if c["key"] != "%s-%s" % (slug, step["unit"]):
            problems.append("key %s" % c["key"])
        if c["title"].strip() != step["title"].strip():
            problems.append("title '%s'" % c["title"])
        if norm(c["assignee"]) != norm(step["lane"]):
            problems.append("assignee %s" % (c["assignee"] or "nobody"))
        if c["status"] != want_status:
            problems.append("status %s, expected %s" % (c["status"], want_status))
        if c["workspace"] != "worktree":
            problems.append("workspace %s" % (c["workspace"] or "none"))
        if c["branch"] != step["branch"]:
            problems.append("branch %s" % (c["branch"] or "none"))
        if c["body"] != read_body("docs/chunks/%s.md" % step["unit"]):
            problems.append("body differs from docs/chunks/%s.md" % step["unit"])
        if after.parents(c["id"]) != sorted(p for p in parents if p):
            problems.append("parents %s, expected %s" % (",".join(after.parents(c["id"])) or "none", ",".join(sorted(p for p in parents if p))))
        if problems:
            return "the new card %s is not what was asked for: %s" % (c["id"], "; ".join(problems))
    elif k == "link":
        parent, child = cid(step["parent"]), cid(step["child"])
        want_links.add((parent, child))
        b, a = before.cards[child], after.cards[child]
        parent_open = after.cards[parent]["status"] not in TERMINAL
        if a["status"] != b["status"] and not (b["status"] == "ready" and a["status"] == "todo" and parent_open):
            return "%s moved %s -> %s after the link" % (name_of(slug, a), b["status"], a["status"])
        if a["assignee"] != b["assignee"]:
            return "%s changed assignee after the link" % name_of(slug, a)
    elif k == "unlink":
        parent, child = cid(step["parent"]), cid(step["child"])
        want_links.discard((parent, child))
        b, a = before.cards[child], after.cards[child]
        if a["status"] != b["status"] and not (child == release and a["status"] == "ready"):
            return "%s moved %s -> %s after the unlink: it was released" % (name_of(slug, a), b["status"], a["status"])
    else:
        child = cid(step["card"])
        b, a = before.cards[child], after.cards[child]
        if a["body"] != read_body("docs/chunks/%s.md" % step["unit"]):
            return "%s: the body read back is not docs/chunks/%s.md" % (name_of(slug, a), step["unit"])
        for f in ("status", "assignee", "title", "branch"):
            if a[f] != b[f]:
                return "%s: %s changed %s -> %s by an edit" % (name_of(slug, a), f, b[f], a[f])
    if after.links != want_links:
        return "the edges are not what this step should leave: unexpected %s, missing %s" % (
            sorted(after.links - want_links) or "none", sorted(want_links - after.links) or "none")
    return None


# ---------------------------------------------------------------------------- cli

def main(argv):
    ap = argparse.ArgumentParser(prog="board-sync-plan.py")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("plan")
    p.add_argument("--units", required=True)
    p.add_argument("--snapshot", required=True)
    p.add_argument("--board", required=True)
    p.add_argument("--allow-release", type=int, default=0)
    p.add_argument("--out", required=True)
    r = sub.add_parser("render")
    r.add_argument("--plan", required=True)
    pre = sub.add_parser("precheck")
    pre.add_argument("--plan", required=True)
    pre.add_argument("--index", type=int, required=True)
    pre.add_argument("--snapshot", required=True)
    pre.add_argument("--allow-release", type=int, default=0)
    post = sub.add_parser("postcheck")
    post.add_argument("--plan", required=True)
    post.add_argument("--index", type=int, required=True)
    post.add_argument("--before", required=True)
    post.add_argument("--after", required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "plan":
            with open(args.units) as fh:
                units = json.load(fh)
            plan = make_plan(units, args.snapshot, args.board, args.allow_release)
            with open(args.out, "w") as fh:
                json.dump(plan, fh)
            return 0
        if args.cmd in ("render", "precheck", "postcheck"):
            with open(args.plan) as fh:
                plan = json.load(fh)
            if args.cmd == "render":
                print(render(plan))
                return 0
            if args.cmd == "precheck":
                res = precheck(plan, args.index, args.snapshot, args.allow_release)
                print(json.dumps(res))
                return 0 if res["ok"] else 1
            msg = postcheck(plan, args.index, args.before, args.after)
            print(msg or "ok")
            return 1 if msg else 0
    except Unreadable as exc:
        sys.stderr.write("board-sync: %s\n" % exc)
        return 2
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
