#!/usr/bin/env bash
# =============================================================================
# forge decision-message — GW1: one format for everything the machine says to
# the operator.
#
# What happened (one line), what it means, the one decision needed, the risk,
# the one reply. No decision, no message. The format exists because judge card
# t_7ad8d58e opened with gate jargon, then a spot-check concluding "not a
# defect", then "Run /judge, then merge or bounce" — three things to read before
# the one thing to do.
#
# SOURCED, NEVER EXECUTED. Every producer that speaks to the operator sources
# this file beside itself (`"$HERE/decision-message.sh"`), so there is one
# format and one place to change it:
#   scripts/prejudge-review.sh  the verifier's holds and its bounce-budget exception
#   scripts/merge-watcher.sh    a hold it cannot finish (closed PR, no PR, a merge
#                               that would not complete)
#   scripts/digest.sh           every card waiting on the operator, whoever blocked it
#   hermes/board-bootstrap.sh   the hold on a milestone gate and on an interactive chunk
#
# THE CLASS TABLE is the second half. A lane block is one line —
# `<class>: <reason>` from rubrics/run-metadata-contract.json — because the lane
# is a program and its reason is data other programs parse. The digest renders
# that line into the full format here, so every block class the contract
# registers has an entry below. `make verify` (`digest/every-block-class-has-a-decision`)
# fails on a registered class with no entry, and on a table that yields no
# classes at all — a check that finds nothing has gone blind, not passed.
# =============================================================================

# $1=class  $2=headline  $3=means  $4=decision  $5=risk  $6=reply
decision_message() {
  printf '%s: %s\n\nWhat it means: %s\nDecision needed: %s\nRisk: %s\nReply: %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# The bootstrap's hold on a chunk a human implements (`Lane: claude-interactive`).
# It is the one mark such a card carries — no title prefix like a gate's, and no
# assignee once the bootstrap takes its sentinel off. The bootstrap blocks the
# card with it, and the digest reads it to keep the card out of "waiting on you"
# while a parent is still open (epic P13). One string, so the two cannot drift;
# `make verify` (`bootstrap/interactive-hold-is-the-reason-the-digest-skips`)
# compares what the bootstrap really writes with this.
#
# It is decision-first (epic P16): until S6c it was the one line
# "interactive chunk: human implementation required", which the digest could
# only render as `other`, risk unknown, for the one held card that is the
# operator's own work. It names no card: it must stay byte-identical on every
# card for the digest's match, and the digest prints the card's id and title
# directly above it.
INTERACTIVE_HOLD_REASON="$(decision_message interactive \
  "this chunk is yours to implement; no lane will pick it up" \
  "the roadmap routed it to a human (Lane: claude-interactive); its children and its milestone gate wait until its PR is merged" \
  "implement it now, or re-plan it for a lane" \
  "nothing is built until you start it, and nothing merges before the verifier has reviewed it" \
  "\`/start-chunk <its CHUNK id>\` in the product checkout; \`/end-chunk\` hands it to the verifier")"

# WHO WAITS ON THE OPERATOR — ONE QUERY, THREE READERS. `forge status` (scripts/forge.sh), the daily
# digest (scripts/digest.sh) and the push watcher (scripts/run-watch.sh) all ask which cards are waiting
# on the operator, and they must give one answer; before this function each held its own copy of the SQL.
# It prints one SQL EXPRESSION (a scalar subquery that yields a JSON array) for the caller to lay into
# its own `json_object(... 'waiting', <this> ...)`. $1 = the handoff sentinel and $2 = the interactive
# hold above, both already SQL-escaped by the caller (doubled quotes). Each element:
#   id, title, status   the card
#   reason              the card's latest block reason (`blocked` or `block_loop_detected`), or, when the
#                       LATEST of those events and `gave_up` is a `gave_up`, a sentence built from that
#                       event: "the worker gave up (<crashed|timed out|...>): <first line of its error>".
#                       The dispatcher blocks a card after a crash or a timeout and writes no `blocked`
#                       event, so before this the card showed a blank or an OLDER reason
#   hold                id of that latest event: what tells one hold of a card from the next
#   gave_up             1 when that event is a `gave_up`
# The `gave_up` payload's `error` is the only error read: it is on every `gave_up` event a real board
# holds, and it is in every fixture's schema, which `task_runs.error` is not.
forge_waiting_sql() {  # $1 sentinel (SQL-escaped)  $2 interactive hold (SQL-escaped)
  cat <<SQL
(SELECT COALESCE(json_group_array(json_object('id', id, 'title', title, 'status', status, 'reason', reason,
                                              'hold', hold, 'gave_up', gave_up)), json_array())
   FROM (SELECT t.id, t.title, t.status, h.id AS hold, COALESCE(h.kind = 'gave_up', 0) AS gave_up,
                CASE WHEN h.kind = 'gave_up'
                     THEN 'the worker gave up'
                          || COALESCE(' (' || replace(json_extract(h.payload,'\$.trigger_outcome'), '_', ' ') || ')', '')
                          || ': ' || COALESCE(NULLIF(trim(substr(json_extract(h.payload,'\$.error'), 1,
                                                  instr(json_extract(h.payload,'\$.error') || char(10), char(10)) - 1)), ''),
                                              'no error was recorded')
                     ELSE json_extract(h.payload,'\$.reason') END AS reason
           FROM tasks t
           LEFT JOIN task_events h ON h.id = (SELECT e.id FROM task_events e
                                               WHERE e.task_id = t.id AND e.kind IN ('blocked','block_loop_detected','gave_up')
                                               ORDER BY e.created_at DESC, e.id DESC LIMIT 1)
          WHERE (t.status IN ('blocked','triage')
                 -- A human chunk sent back for changes (epic P21): ready, on the non-spawnable sentinel.
                 OR (t.status = 'ready' AND t.assignee IS '$1'))
            -- A milestone gate (epic MS1) is held from the moment the board is bootstrapped, but it asks
            -- nothing until every chunk it closes is done. Before that it is not waiting on the operator,
            -- and GW1 says no decision, no message.
            AND NOT (t.title GLOB 'GATE-*' AND t.status = 'blocked'
                     AND EXISTS (SELECT 1 FROM task_links l
                                   JOIN tasks p ON p.id = l.parent_id
                                  WHERE l.child_id = t.id
                                    AND p.status NOT IN ('done','archived')))
          ORDER BY t.id) w
  -- An interactive chunk (epic P13) is held from the bootstrap on as well, and asks nothing while a parent
  -- is open: the human cannot start it yet. Its one mark is the reason the bootstrap blocked it with, and
  -- only as its LAST reason, so a later block still speaks. IS, not =: a card blocked with no recorded
  -- reason must stay.
  WHERE NOT (w.status = 'blocked' AND w.reason IS '$2'
             AND EXISTS (SELECT 1 FROM task_links l
                           JOIN tasks p ON p.id = l.parent_id
                          WHERE l.child_id = w.id
                            AND p.status NOT IN ('done','archived'))))
SQL
}

# $1=class -> four lines on stdout: means, decision, risk, reply. The reply may
# name `<id>` and `<board>`; the caller substitutes them. Exit 1 for a class
# with no entry, so a caller can tell "unknown" from "empty".
class_decision() {
  case "$1" in
    stale-spec) printf '%s\n' \
      "the card has no contract a lane can implement — its body is empty or out of date" \
      "fix the chunk contract" \
      "this chunk and every child of it wait; nothing was built" \
      "edit the card body, then \`hermes kanban --board <board> unblock <id>\`";;
    failing-prereq) printf '%s\n' \
      "a parent this chunk builds on is not merged, so building now would build on code that is not on main" \
      "merge the parent, or change the dependency" \
      "this chunk waits; nothing was built on the unmerged parent" \
      "merge the parent PR, then \`hermes kanban --board <board> unblock <id>\`";;
    env) printf '%s\n' \
      "the host could not do something the run needs — a tool, the remote, a workspace, or a usage limit past its wait" \
      "repair what the reason names" \
      "nothing was merged; the card holds until it is unblocked" \
      "fix it, then \`hermes kanban --board <board> unblock <id>\`";;
    ci-red) printf '%s\n' \
      "\`make check\` was red on the implementer's branch, so no PR was handed to review" \
      "repair the branch, or re-plan the chunk" \
      "this chunk and its children wait; nothing reached review" \
      "push a fix to the branch and \`hermes kanban --board <board> unblock <id>\`";;
    judge-bounce) printf '%s\n' \
      "the card came back from review with no recorded reason, so the lane has nothing to fix" \
      "say what to fix" \
      "the lane will not guess; the chunk waits" \
      "\`hermes kanban --board <board> unblock <id> --reason \"<what to fix>\"\`";;
    gate-misrouted) printf '%s\n' \
      "a card reached a profile that must not run it" \
      "reassign it to the right profile" \
      "nothing ran on it; it waits where it is" \
      "\`hermes kanban --board <board> assign <id> <profile>\`, then unblock it";;
    gate-unrunnable) printf '%s\n' \
      "the verifier could not run its gate — GitHub, the network or a tool failed — so there is no verdict" \
      "re-run the review once the cause is fixed" \
      "nothing was judged and nothing was merged" \
      "\`hermes kanban --board <board> unblock <id>\` to run the review again";;
    merge-pending) printf '%s\n' \
      "the verifier passed this chunk and may only recommend, so the merge is yours" \
      "merge the PR, or send it back" \
      "its children stay held until it merges" \
      "merge the PR on GitHub — the merge-watcher completes the card — or \`~/.forge/repo/scripts/bounce.sh <id> \"<reason>\" --board <board>\`";;
    bounce-budget) printf '%s\n' \
      "two verifier bounces did not converge; a third machine round is not evidence of anything new" \
      "repair it yourself, amend the contract, or send it back for another round" \
      "the card is held and its children with it; nothing is merged" \
      "push a fix to the PR branch, or \`~/.forge/repo/scripts/bounce.sh <id> \"<reason>\" --board <board>\`";;
    other) printf '%s\n' \
      "something outside the known block classes stopped this card" \
      "read the reason and decide" \
      "unknown — the card holds until someone looks" \
      "\`hermes kanban --board <board> show <id>\`";;
    *) return 1;;
  esac
}

# The classes the table above answers, one per line. Read by make verify, which
# compares it with the contract's registry in both directions.
decision_classes() {
  sed -n 's/^    \([a-z][a-z-]*\)) printf .*/\1/p' "${BASH_SOURCE[0]}"
}
