"""Syncing can be paused — the class of JobApp C17's finding, at its strongest.

C17's Then step checked that one word was absent, so the paused-path message
could be reworded freely. Here no test reads that message at all, so deleting
or emptying it is unseen. (The real C17 also asserted a prefix of the message
elsewhere, which a deletion does trip — see the recorded replay.)
"""


def run_sync(items: list[str], *, enabled: bool) -> int:
    if not enabled:
        print("sync: paused")
        return 0
    for item in items:
        print(f"sync: {item}")
    return len(items)
