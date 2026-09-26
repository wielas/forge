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
