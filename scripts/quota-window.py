#!/usr/bin/env python3
"""Decide whether Codex's usage windows permit work, and when they next won't.

Codex quota moved from a flat weekly allowance to rolling shorter windows, and
the shape is *server-reported*, not something this repo may assume. Every
`token_count` event `codex exec --json` emits carries a `rate_limits` object:

    "rate_limits": {"limit_id": "codex", "primary": {"used_percent": 45.0,
     "window_minutes": 10080, "resets_at": 1786854650}, "secondary": null,
     "credits": {...}, "plan_type": "plus", "rate_limit_reached_type": null}

Two rules follow from that, and both are load-bearing:

**Never key off `window_minutes`.** Rollouts on the machine this was written on
still show the old shape (one window, 10080 minutes, `secondary: null`); the
new regime reports different numbers. A branch on `== 300` would be correct for
exactly one quota policy and silently wrong for the next. So: a window is any
member of `rate_limits` that carries `used_percent`/`resets_at`, whatever it is
called, and the wait comes from `resets_at` — an absolute epoch the provider
states, not a duration we guess.

**Wake to the LATEST reset among exhausted windows, not the nearest.** If a
short window clears in two hours and the weekly one clears in four days, waking
at two hours wakes straight back into a block, and a lane that does that in a
loop burns the night making no progress. `max`, never `min`.

Two corollaries, each of which is the same mistake seen from the other side:

**Only over the windows that are actually blocked**, and when the provider
NAMES the window it refused on (`rate_limit_reached_type`), only that one. A
spent short window beside a healthy weekly one is the normal shape under the
rolling regime; blocking on both there sleeps five days because five hours
filled -- which burns the night just as thoroughly as waking too early.

**A reset already in the past is stale evidence, not a live block.** The
snapshot describes a window that has since reset. This is what keeps a
pre-flight read of an old session rollout, or of a log holding an earlier
attempt, from parking on a limit that expired hours ago.

Output is one line on stdout:

    clear
    blocked wake_at=<epoch> windows=<csv>
    blocked wake_at=unknown windows=<csv>
    unknown <reason>

Exit 0 for any decision (`clear` or `blocked` — a block is a result, not a
failure), 3 when there is nothing to judge, 2 for a usage error. 1 is
deliberately unused so a caller under `set -e` cannot read a decision as a
crash (ADR-0010 D10.3).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import time
from typing import Any, Iterator

# Members of `rate_limits` that are not windows. This list is a comment, not a
# filter: the actual test is "does it carry used_percent or resets_at", so an
# unforeseen sibling key cannot be mistaken for a window and an unforeseen
# *window* is still found. `credits` is the one that would otherwise tempt a
# name-based filter -- it is a dict, and it has neither field.
NOT_WINDOWS = ("limit_id", "limit_name", "credits", "individual_limit",
               "spend_control_reached", "plan_type", "rate_limit_reached_type")

# The stream says the limit was actually hit, as opposed to merely being near.
# Codex spells this several ways depending on where it surfaces; treat any of
# them as authoritative, because a hard signal outranks a percentage.
REACHED_MARKERS = ("usage_limit_reached", "rate_limit_reached",
                   "usage_limit_exceeded", "quota_exceeded")

# Codex also refuses in PLAIN TEXT, with no `rate_limits` object anywhere in the
# stream. Observed on redglass CHUNK-6 and CHUNK-8; the event, verbatim from
# rollout 01a07acc (2026-09-07T07:36:41Z), is
#
#   {"type":"event_msg","payload":{"type":"task_complete","error":{"message":
#    "You've hit your usage limit. Upgrade to Pro (...) or try again at
#    11:55 AM.","codex_error_info":"usage_limit_exceeded"}}}
#
# `decide` raised `no-rate-limit-data`, `codex-run.sh` read exit 3 as "not a
# usage limit" and exited 4, and the lane improvised a ~3 h heartbeat wait for a
# window that in fact lifted in 2 h 19 m. The stated time IS the reset; it is
# merely prose instead of an epoch. So it is parsed -- and parsed ONLY out of
# the refusal's own message, never out of any string in the stream: a chunk that
# builds a rate limiter prints "usage limit" in agent text all day, and
# `quota/non-quota-failure-is-not-parked` must stay green.
#
# Two spellings have been seen in real rollouts. Both are matched; the dated one
# first, because it contains the bare one.
_MONTHS = {m: i + 1 for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun",
     "jul", "aug", "sep", "oct", "nov", "dec"))}
# "…or try again at Aug 5th, 2026 9:53 AM."
RESET_DATED = re.compile(
    r"try again at\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+"
    r"(\d{4})\s+(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]", re.I)
# "…or try again at 11:55 AM."
RESET_CLOCK = re.compile(
    r"try again at\s+(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]", re.I)


def _to_24h(hour: int, meridiem: str) -> int:
    """12-hour clock to 24-hour. 12 AM is 0; 12 PM is 12."""
    hour %= 12
    return hour + (12 if meridiem.lower() == "p" else 0)


def parse_stated_reset(message: str, anchor: int) -> int | None:
    """The epoch a refusal MESSAGE says work may resume, or None.

    The time is rendered in the operator's own timezone with no zone marker, so
    it is resolved in local time -- the same clock that printed it. A DST fold
    can move the answer by an hour, which is bounded and self-correcting: the
    caller re-probes on its floor.

    `anchor` is the moment the refusal was WRITTEN, not now, and the bare clock
    form resolves to the next occurrence strictly after it. Anchoring to `now`
    instead would make a stale rollout read at pre-flight -- an hours-old
    refusal, already lifted -- park until this afternoon's 11:55, which is the
    very mistake `_is_stale` exists to prevent. Anchored to the event, the same
    stale refusal resolves into the past and is discarded as stale evidence.
    """
    dated = RESET_DATED.search(message)
    if dated:
        mon, day, year, hour, minute, meridiem = dated.groups()
        month = _MONTHS.get(mon[:3].lower())
        if month is None:
            return None
        try:
            return int(dt.datetime(int(year), month, int(day),
                                   _to_24h(int(hour), meridiem),
                                   int(minute)).timestamp())
        except ValueError:
            return None

    clock = RESET_CLOCK.search(message)
    if not clock:
        return None
    hour, minute, meridiem = clock.groups()
    if int(minute) > 59:
        return None
    when = dt.datetime.fromtimestamp(anchor)
    try:
        candidate = when.replace(hour=_to_24h(int(hour), meridiem),
                                 minute=int(minute), second=0, microsecond=0)
    except ValueError:
        return None
    if candidate <= when:
        candidate += dt.timedelta(days=1)
    return int(candidate.timestamp())


def find_refusal_messages(obj: Any) -> Iterator[str]:
    """Yield the `message` of every object that is ITSELF a refusal.

    The marker and the message must sit in the SAME dict. That is what keeps
    this on the error channel: `{"message": …, "codex_error_info":
    "usage_limit_exceeded"}` matches, and a model's prose about usage limits --
    which carries no marker beside it -- does not.
    """
    if isinstance(obj, dict):
        message = obj.get("message")
        if isinstance(message, str) and any(
                v in REACHED_MARKERS for v in obj.values()
                if isinstance(v, str)):
            yield message
        for value in obj.values():
            yield from find_refusal_messages(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from find_refusal_messages(value)


def event_time(obj: Any, default: int) -> int:
    """The epoch this event was written, searched by key, else `default`.

    By key and not by path, for the same reason `find_rate_limits` is: the two
    streams this script is actually pointed at have different envelopes.

    - The pre-flight gate reads the newest **session rollout**, which nests the
      payload under `payload` and stamps each line with a top-level ISO
      `timestamp`. That is the stale-evidence path -- an hours-old refusal read
      before a run starts -- and it is exactly the path the anchor exists for.
    - The reactive check reads `$CURRENT`, the live `codex exec --json` stream,
      whose events (`thread.started`, `item.completed`, …) carry **no time
      field at all**; measured on the one real stream on this machine,
      `~/.forge/lane-quarantine/20260902-142534/scratch-forge-lane-1`.

    So the fallback to `default` is not a corner: it is the normal answer on
    the reactive path, and it is the right one there, because the stream was
    written seconds ago and `default` is now.
    """
    if isinstance(obj, dict):
        stamp = obj.get("timestamp")
        if isinstance(stamp, str):
            try:
                return int(dt.datetime.fromisoformat(
                    stamp.replace("Z", "+00:00")).timestamp())
            except ValueError:
                pass
        if isinstance(stamp, (int, float)) and not isinstance(stamp, bool):
            return int(stamp)
        for value in obj.values():
            found = event_time(value, 0)
            if found:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = event_time(value, 0)
            if found:
                return found
    return default


# The furthest ahead a stated reset may be and still be believed. A provider
# that moves `resets_at` to epoch MILLISECONDS -- an ordinary API change, and
# the shape most likely to arrive unannounced -- reports ~1.79e12, which reads
# as the year 58000. Sleeping on that is indistinguishable from hanging, and
# guessing that it "must be" milliseconds and dividing is inventing data. So an
# incredible reset is treated as no reset at all: still blocked, wake unknown,
# and the caller re-probes on its own floor until the provider says something
# usable. 400 days clears the longest window any plan documents.
WAKE_HORIZON = 400 * 86400


class Unjudgeable(Exception):
    """The input carried no rate-limit information at all."""


def iter_json_objects(text: str) -> Iterator[Any]:
    """Yield every parseable JSON value in a JSONL stream, skipping junk.

    A live `codex exec --json` stream is not guaranteed to be pure JSONL: a
    wrapper may have teed a banner into it, and a killed process can leave a
    torn final line. A parser that dies on the first unparseable line would
    throw away the rate-limit data sitting on the lines before it, which is
    exactly the data needed to decide how long to sleep.
    """
    for line in text.splitlines():
        line = line.strip()
        if not line or line[0] not in "{[":
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def find_rate_limits(obj: Any) -> Iterator[dict]:
    """Yield every `rate_limits` object nested anywhere inside `obj`.

    The event is wrapped differently depending on the source: a session rollout
    nests it under `payload`, the `--json` stream may not, and an error event
    carries one beside `resets_at`. Searching by key rather than by path means
    this keeps working when the envelope changes and only the payload matters.
    """
    if isinstance(obj, dict):
        rl = obj.get("rate_limits")
        if isinstance(rl, dict):
            yield rl
        for value in obj.values():
            yield from find_rate_limits(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from find_rate_limits(value)


def contains_reached_marker(obj: Any) -> bool:
    """True if any string anywhere in `obj` is a limit-reached marker."""
    if isinstance(obj, str):
        return obj in REACHED_MARKERS
    if isinstance(obj, dict):
        return any(contains_reached_marker(v) for v in obj.values())
    if isinstance(obj, list):
        return any(contains_reached_marker(v) for v in obj)
    return False


def windows_of(rate_limits: dict) -> list[tuple[str, dict]]:
    """Every member of `rate_limits` that looks like a usage window."""
    found = []
    for name, value in rate_limits.items():
        if not isinstance(value, dict):
            continue
        if "used_percent" in value or "resets_at" in value:
            found.append((name, value))
    return found


def _number(value: Any) -> float | None:
    """A JSON number, or None for null/absent/non-numeric. Never a guess."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def decide(rate_limits: dict | None, threshold: float,
           reached: bool = False, now: int | None = None) -> str:
    """Return the one-line verdict for these windows."""
    if rate_limits is None:
        raise Unjudgeable("no-rate-limit-data")
    if now is None:
        now = int(time.time())

    windows = windows_of(rate_limits)
    if not windows and not reached:
        raise Unjudgeable("no-usage-windows-reported")

    # A window whose used_percent is null is *unknown*, not *clear*. Counting
    # it as clear would let a missing field license a start, which is the
    # failure mode where a parser silently stops parsing and everything looks
    # fine right up until the run dies. A negative percentage is corrupt in the
    # same way and gets the same answer: unknown, never clear.
    blocked: list[tuple[str, dict]] = []
    unreadable: list[str] = []
    for name, window in windows:
        used = _number(window.get("used_percent"))
        if used is None or used < 0:
            unreadable.append(name)
        elif used >= threshold:
            blocked.append((name, window))

    # `rate_limit_reached_type` set, or a reached marker in the stream, means
    # the provider already refused, and a stated refusal outranks a percentage.
    #
    # But when the provider names WHICH window it refused on, that name is the
    # most precise fact in the payload, and widening it to every window is how
    # a spent five-hour window comes to sleep until a healthy weekly one resets
    # -- five days of holding a card and a worktree because of one hour. Fall
    # back to every window only when the refusal is anonymous.
    reached_type = rate_limits.get("rate_limit_reached_type")
    hard = reached or reached_type is not None
    if hard and not windows:
        # Refused, with nothing to say when it lifts. `clear` would be a lie;
        # a block with no wake time would park the caller on its floor forever
        # against a snapshot that can never change. Neither: say so and let the
        # caller route it as the environment failure it is.
        raise Unjudgeable("limit-reached-without-window-data")
    if hard and not blocked:
        named = [(n, w) for n, w in windows if n == reached_type]
        blocked = named if named else windows

    if not blocked:
        if unreadable:
            raise Unjudgeable(
                "unreadable-used-percent:" + ",".join(sorted(unreadable)))
        return "clear"

    # A stated reset that has already passed describes a window which has since
    # reset. Believing it is how a run parks on an hours-old limit -- either
    # from a stale rollout at pre-flight, or from an earlier attempt still
    # sitting in a log. Stale evidence licenses nothing.
    live = [(name, window) for name, window in blocked
            if not _is_stale(window, now)]
    if not live:
        return "clear"
    blocked = live

    names = ",".join(name for name, _ in blocked)
    resets = [r for r in (_number(w.get("resets_at")) for _, w in blocked)
              if r is not None and r <= now + WAKE_HORIZON]
    if not resets:
        # Blocked, but the provider did not say until when -- or said something
        # not credible. Saying `clear` here would be a lie and sleeping on a
        # made-up epoch would be worse; the caller falls back to a bounded
        # re-probe, which self-corrects as soon as the provider says anything.
        return f"blocked wake_at=unknown windows={names}"
    return f"blocked wake_at={int(max(resets))} windows={names}"


def _is_stale(window: dict, now: int) -> bool:
    """True if this window's stated reset has already passed."""
    reset = _number(window.get("resets_at"))
    return reset is not None and reset <= now


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Decide whether Codex usage windows permit work.")
    src = parser.add_mutually_exclusive_group()
    src.add_argument("stream", nargs="?", default="-",
                     help="JSONL file from `codex exec --json` ('-' = stdin)")
    src.add_argument("--rate-limits", metavar="JSON",
                     help="a rate_limits object, instead of a stream")
    parser.add_argument("--threshold", type=float, default=95.0,
                        help="used_percent at or above which a window blocks")
    parser.add_argument("--now", type=int, default=None,
                        help="override the clock (seconds since epoch)")
    args = parser.parse_args(argv)

    if not 0 < args.threshold <= 100:
        print(f"usage: --threshold must be in (0, 100], got {args.threshold}",
              file=sys.stderr)
        return 2

    reached = False
    if args.rate_limits is not None:
        try:
            rate_limits = json.loads(args.rate_limits)
        except json.JSONDecodeError as exc:
            print(f"usage: --rate-limits is not JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(rate_limits, dict):
            print("usage: --rate-limits must be a JSON object", file=sys.stderr)
            return 2
    else:
        try:
            text = (sys.stdin.read() if args.stream == "-"
                    else open(args.stream, encoding="utf-8").read())
        except OSError as exc:
            # stdout, like every other verdict: a caller that captures this
            # command's output must see a word it can route, not an empty
            # string it has to guess about.
            print(f"unknown unreadable-stream:{exc}")
            return 3
        # Last one wins: the newest event holds the current state.
        #
        # And `reached` is scoped to that state, not to the file. A marker is
        # evidence about the moment it was written; carrying it forward over a
        # FRESHER snapshot means one refused attempt condemns every later
        # reading of the same log, however healthy the provider says the
        # windows now are. A new snapshot supersedes the markers before it.
        rate_limits = None
        stated_reset = None
        clock_now = args.now if args.now is not None else int(time.time())
        for obj in iter_json_objects(text):
            fresh = False
            for found in find_rate_limits(obj):
                rate_limits = found
                fresh = True
            marker = contains_reached_marker(obj)
            reached = marker if fresh else (reached or marker)
            # A plain-text refusal is superseded by a fresher structured
            # snapshot for exactly the reason `reached` is: it is evidence about
            # the moment it was written, not a standing condition.
            here = None
            for message in find_refusal_messages(obj):
                here = parse_stated_reset(message, event_time(obj, clock_now))
                if here is not None:
                    break
            stated_reset = here if fresh else (here or stated_reset)

        # No structured windows at all, but the provider refused in prose and
        # said when it lifts. Synthesise the window that sentence describes, so
        # a caller gets `blocked wake_at=<epoch>` and parks, instead of the
        # `unknown no-rate-limit-data` that routed redglass CHUNK-6/8 to "not a
        # usage limit". A window invented here is spent by definition: the
        # provider did not estimate, it refused.
        if rate_limits is None and stated_reset is not None:
            rate_limits = {"limit_id": "codex-plaintext",
                           "stated": {"used_percent": 100.0,
                                      "resets_at": stated_reset}}

    try:
        verdict = decide(rate_limits, args.threshold, reached=reached,
                         now=args.now)
    except Unjudgeable as exc:
        print(f"unknown {exc}")
        return 3

    print(verdict)
    return 0


if __name__ == "__main__":
    sys.exit(main())
