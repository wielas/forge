# Fixture for scripts/prejudge-steps.py. Every shape below is either a real
# defect the audit cites by file and line (F14), or a legitimate step the walker
# must NOT report — false positives are how a gate gets switched off.
#
# The expectation is checked EXACTLY against
# scripts/fixtures/prejudge-steps-expected.json, so a new offender kind or a
# vanished one fails a case rather than passing quietly.

import pytest
from pytest_bdd import given, then, when


@given("a board")
def a_board():
    return {"cards": 1}


@when("it is read")
def it_is_read(a_board):
    a_board["read"] = True


# --- must be reported --------------------------------------------------------


@then("the report is produced")
def then_no_assertion_at_all(a_board):
    # The defect class: computes, returns, and claims nothing. pytest-bdd marks
    # the scenario green regardless of what the code under test did.
    result = a_board["cards"] > 0
    return result


@then("rendering is deterministic")
def then_tautology(a_board):
    # test_render.py:198-200 verbatim — both sides move together, so this
    # passes whatever render() does.
    assert render(a_board) == render(a_board)


@then("the count is stable")
def then_tautology_identity(a_board):
    assert a_board is a_board


# --- must NOT be reported ----------------------------------------------------


@then("the card count is one")
def then_plain_assert(a_board):
    assert a_board["cards"] == 1


@then("reading twice is stable")
def then_compares_two_different_expressions(a_board):
    # Superficially similar to the tautology above and legitimately different:
    # a recorded value against a recomputed one is the real determinism claim.
    first = render(a_board)
    assert first == render(a_board)


@then("an unknown card is refused")
def then_pytest_raises(a_board):
    with pytest.raises(KeyError):
        a_board["missing"]


@then("the failure is explicit")
def then_pytest_fail(a_board):
    if a_board["cards"] < 0:
        pytest.fail("negative cards")
    assert a_board["cards"] >= 0


@then("the helper asserts for us")
def then_assert_helper(a_board):
    # A step whose claim is delegated to an assert* helper still makes a claim.
    assert_card_count(a_board, 1)


@then("the private helper asserts for us")
def then_private_assert_helper(a_board):
    # Regression: the walker reported four of exactly this shape as
    # `no-assertion` on forgeboard-report PR #11 — Then steps delegating to a
    # module-private `_assert_failures` that asserts four times. The leading
    # underscore defeated the prefix test.
    _assert_card_count(a_board, 1)


def render(board):
    return str(board)


def assert_card_count(board, n):
    assert board["cards"] == n


def _assert_card_count(board, n):
    assert board["cards"] == n


# A plain unit test, not a Then step. `no-assertion` must not be reported here —
# that is a different argument — but a tautology must be, because the defect the
# audit cites for F14 lives in exactly this shape.
def test_plain_unit_tautology():
    board = {"cards": 1}
    assert render(board) == render(board)


def test_plain_unit_without_assertion():
    board = {"cards": 1}
    return board["cards"]
