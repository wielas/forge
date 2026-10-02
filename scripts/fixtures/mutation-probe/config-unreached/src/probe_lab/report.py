"""A report whose options come from config — the class of JobApp C21's blocker.

The tests below drive `render_report` with keyword arguments directly, and the
one test that goes through `report_from_config` checks only that an item is
listed. So the config reads are executed but decide nothing a test checks:
delete or invert any of them and every test still passes.
"""

DEFAULT_FOOTER = True
DEFAULT_LIMIT = 0


def render_report(items: list[str], *, footer: bool, limit: int) -> str:
    shown = items[:limit] if limit > 0 else items
    lines = [f"- {item}" for item in shown]
    if footer:
        lines.append("-- sent by probe-lab")
    return "\n".join(lines)


def report_from_config(config: dict, items: list[str]) -> str:
    footer = (
        DEFAULT_FOOTER
        if config.get("report.footer") is None
        else config.get("report.footer") is True
    )
    limit = int(config.get("report.limit", DEFAULT_LIMIT))
    return render_report(items, footer=footer, limit=limit)
