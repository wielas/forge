-- WAL-mode board fixture for the opt-in live metadata sweep. The cutoff used
-- by verify.sh is 2026-08-09T00:00:00Z (1786233600). Rows immediately before
-- and after it make the scope boundary reviewable without a binary fixture.
PRAGMA journal_mode=wal;

CREATE TABLE task_runs (
    id         INTEGER PRIMARY KEY,
    task_id    TEXT NOT NULL,
    profile    TEXT,
    status     TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    ended_at   INTEGER,
    outcome    TEXT,
    metadata   TEXT
);

CREATE TABLE task_events (
    id         INTEGER PRIMARY KEY,
    task_id    TEXT NOT NULL,
    run_id     INTEGER,
    kind       TEXT NOT NULL,
    payload    TEXT,
    created_at INTEGER NOT NULL
);

INSERT INTO task_runs
       (id, task_id, profile, status, started_at, ended_at, outcome, metadata)
VALUES
  (1, 't_chunk_good', 'forge-codex-lane', 'done', 1786233660, 1786233720,
   'completed',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-4","project":"metadata-live-fixture","branch":"chunk/4-metadata-live","pr":"https://github.com/example/metadata-live-fixture/pull/4","lane":"forge-codex-lane","scenarios":{"added":5,"passing":5,"feature_files":["tests/features/chunk_4.feature"]},"check":{"green":true,"coverage_pct":100},"files_changed":6,"lines_changed":200,"decisions":[],"debt":[],"card_proposals":[],"docs_reconciled":["docs/operator-guide.md"],"duration_min":20,"worker":"codex/gpt-5.6-sol xhigh"}'),
  (2, 't_judge_good', 'forge-prejudge', 'done', 1786233780, 1786233840,
   'completed',
   '{"schema":"forge.judge.v1","chunk_id":"CHUNK-4","pr":"https://github.com/example/metadata-live-fixture/pull/4","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":3,"architectural_conformance":3,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3},"findings":[],"nits_as_cards":[],"spot_check_suggestion":"","judge_model":"opus","tokens_estimate":1200}'),
  (3, 't_old_nested', 'forge-codex-lane', 'done', 1786233540, 1786233580,
   'completed',
   '{"forge.chunk.v1":{"chunk_id":"CHUNK-OLD"}}'),
  -- Completed runs from profiles outside the producer registry are unrelated
  -- to this sweep and do not enter any of its four counts.
  (4, 't_other_profile', 'default', 'done', 1786233900, 1786233960,
   'completed', '{"freeform":"operator result"}');

INSERT INTO task_events (id, task_id, run_id, kind, payload, created_at) VALUES
  (1, 't_chunk_good', 1, 'blocked',
   '{"reason":"env: fixture capability was unavailable","kind":"needs_input"}',
   1786233720),
  -- Even an invalid historical reason is ignored when it predates SINCE.
  (2, 't_old_nested', 3, 'blocked',
   '{"reason":"historical free-form reason","kind":"needs_input"}',
   1786233540),
  -- A manual event has no run id and therefore was not model-authored.
  (3, 't_manual', NULL, 'blocked',
   '{"reason":"manual operator note","kind":"needs_input"}',
   1786233900);
