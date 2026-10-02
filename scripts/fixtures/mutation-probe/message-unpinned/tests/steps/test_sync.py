"""The Then checks one word, so the paused-path message can say anything."""

from pytest_bdd import given, scenarios, then, when

from probe_lab.sync import run_sync

scenarios("../features/sync.feature")


@given("two items and syncing paused", target_fixture="setup")
def paused():
    return {"items": ["alpha", "beta"], "enabled": False}


@given("two items and syncing on", target_fixture="setup")
def on():
    return {"items": ["alpha", "beta"], "enabled": True}


@when("syncing runs", target_fixture="result")
def runs(setup, capsys):
    synced = run_sync(setup["items"], enabled=setup["enabled"])
    return {"synced": synced, "output": capsys.readouterr().out}


@then("nothing is synced and nothing is queued")
def nothing(result):
    assert result["synced"] == 0
    assert "queued" not in result["output"].casefold()


@then("both items are synced")
def both(result):
    assert result["synced"] == 2
    assert result["output"].splitlines() == ["sync: alpha", "sync: beta"]
