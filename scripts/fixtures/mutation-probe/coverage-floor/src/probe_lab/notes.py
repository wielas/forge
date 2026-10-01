"""A call whose only effect is to run another function — the coverage-floor trap.

Deleting `note("described")` leaves `note`'s body unexecuted. Nothing asserts on
what `note` records, so the mutant survives — unless the probe's test run keeps
the project's `--cov-fail-under`, in which case the coverage drop fails the run
and a survivor reads as a kill.
"""

SEEN: list[str] = []


def note(label: str) -> None:
    SEEN.append(label)


def describe(n: int) -> str:
    note("described")
    return "positive" if n > 0 else "non-positive"
