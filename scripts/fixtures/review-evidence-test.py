#!/usr/bin/env python3
"""Standalone, isolated regression for review history and applied bounces."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

SCRIPTS = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    verdict_root = root / "verdicts"
    verdict_root.mkdir()
    latest = verdict_root / "board-chunk.json"
    latest.write_text('{"latest":true}\n')
    payload = root / "payload.json"
    examples = [
        {"schema": "forge.mergecheck.v1", "result": "fail", "detail": "raw evidence"},
        {"schema": "forge.judge.v1", "verdict": "bounce", "usage": {"tokens": 42}, "cost": None},
    ]
    for action, example in zip(("bounce", "exception"), examples):
        payload.write_text(json.dumps(example))
        subprocess.run(["python3", str(SCRIPTS / "verdict-archive.py"), str(verdict_root),
                        "board", "chunk", action, str(payload)], check=True)
    records = [json.loads(p.read_text()) for p in (verdict_root / "history").glob("*.json")]
    assert len(records) == 2
    assert {r["action"] for r in records} == {"bounce", "exception"}
    assert all(r["payload"] in examples for r in records)
    assert latest.read_text() == '{"latest":true}\n'
    payload.write_text("invalid json")
    bad = subprocess.run(["python3", str(SCRIPTS / "verdict-archive.py"), str(verdict_root),
                          "board", "chunk", "bounce", str(payload)], capture_output=True)
    assert bad.returncode != 0 and len(list((verdict_root / "history").glob("*.json"))) == 2

    dry_root = root / "dry-state"
    dry = subprocess.run([str(SCRIPTS / "prejudge-review.sh"),
                          "https://github.com/example/project/pull/8", "--chunk", "t_fixture",
                          "--fixture", str(SCRIPTS / "fixtures/prejudge-prs/pr-8"), "--dry-run"],
                         env=dict(os.environ, FORGE_STATE_ROOT=str(dry_root), FORGE_VERDICT_ROOT=str(dry_root / "verdicts")),
                         input="fixture contract", capture_output=True, text=True)
    assert dry.returncode == 4, dry.stderr
    assert json.loads(dry.stdout)["action"] == "gate-block", dry.stdout
    assert not dry_root.exists(), "a dry-run must not create review history"

    board = root / "kanban" / "boards" / "test"
    board.mkdir(parents=True)
    with sqlite3.connect(board / "kanban.db") as db:
        db.executescript((SCRIPTS / "fixtures/metrics-board-fl3.sql").read_text())
    env = dict(os.environ, HERMES_HOME=str(root), HERMES_KANBAN_HOME=str(root / "kanban"))
    def metrics(*args):
        return json.loads(subprocess.check_output([str(SCRIPTS / "metrics.sh"), "test", "--json", *args], env=env))
    report = metrics()
    assert report["applied_bounces"]["events"] == 3
    assert report["applied_bounces"]["chunks"] == 2
    assert metrics("--since", "2030-01-01")["applied_bounces"]["events"] == 0
    print("review evidence and event-based bounce metrics: passed")
