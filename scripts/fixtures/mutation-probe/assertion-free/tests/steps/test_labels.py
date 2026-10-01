"""CI-green and assertion-free: the Then step RETURNS its comparison.

pytest-bdd discards a step's return value, so this scenario passes whatever
normalize_label does. It is the shape `t_624586d7` bounced in July.
"""

from pytest_bdd import given, parsers, scenarios, then, when

from probe_lab.labels import normalize_label

scenarios("../features/labels.feature")


@given(parsers.parse('the label "{raw}"'), target_fixture="raw")
def raw_label(raw):
    return raw


@when("it is normalised", target_fixture="normalized")
def normalized(raw):
    return normalize_label(raw)


@then(parsers.parse('the result is "{expected}"'))
def then_normalized_label(normalized, expected):
    return normalized == expected
