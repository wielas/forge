"""The same scenario, with an assertion the deterministic gate accepts.

`prejudge-steps.py` blocks a Then step with no assertion (F14), so the literal
`t_624586d7` shape never reaches the mutation probe. This one asserts — but only
a property every output of normalize_label has, so it holds whatever the code
does. The gate's floor cannot see that; a mutation can.
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
    assert isinstance(normalized, str)
