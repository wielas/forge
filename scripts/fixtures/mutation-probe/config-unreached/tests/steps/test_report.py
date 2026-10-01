"""The Givens name config keys, but write the options straight in."""

from pytest_bdd import given, parsers, scenarios, then, when

from probe_lab.report import render_report, report_from_config

scenarios("../features/report.feature")


@given("two items", target_fixture="items")
def items():
    return ["alpha", "beta"]


@when("the report is rendered without a footer", target_fixture="report")
def without_footer(items):
    return render_report(items, footer=False, limit=0)


@when(parsers.parse("the report is rendered with a limit of {n:d}"), target_fixture="report")
def with_limit(items, n):
    return render_report(items, footer=True, limit=n)


@when("the report is rendered from an empty config", target_fixture="report")
def from_config(items):
    return report_from_config({}, items)


@then("the report has no footer")
def no_footer(report):
    assert "sent by" not in report
    assert report == "- alpha\n- beta"


@then(parsers.parse("the report lists {n:d} item"))
def lists_n(report, n):
    assert [line for line in report.splitlines() if line.startswith("- ")] == ["- alpha"][:n]
    assert report.endswith("-- sent by probe-lab")


@then("the report lists alpha")
def lists_alpha(report):
    assert "- alpha" in report
