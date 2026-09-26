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
  -- Since epic FL4 the reviewer profile is `forge-verifier`, and its verdict
  -- reaches a run the only way it can: `block` and `request-changes` take no
  -- --metadata, so the envelope rides the COMPLETION — the verifier's own in
  -- merge mode, or the merge-watcher's once the operator has merged. Both are
  -- `profile = forge-verifier`, `outcome = completed`. The forge-prejudge row
  -- above is the same producer under its old name, kept because the recorded
  -- boards are full of it.
  (10, 't_verifier_good', 'forge-verifier', 'done', 1786234100, 1786234160,
   'completed',
   '{"schema":"forge.judge.v1","chunk_id":"CHUNK-5","pr":"https://github.com/example/metadata-live-fixture/pull/5","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":3,"architectural_conformance":3,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3},"findings":[],"nits_as_cards":[],"spot_check_suggestion":"run the sync twice","judge_model":"opus","tokens_estimate":1400}'),
  (3, 't_old_nested', 'forge-codex-lane', 'done', 1786233540, 1786233580,
   'completed',
   '{"forge.chunk.v1":{"chunk_id":"CHUNK-OLD"}}'),
  -- Since epic FL3 the lane hands a chunk to same-card review, so its envelope
  -- rides the `review_requested` run that `request-review` closes, and the card
  -- is never COMPLETED by the lane at all. Epic P4: a sweep reading only
  -- `outcome = completed` never saw this row, and a board of nothing but
  -- post-FL3 chunks read as "missing producer=forge-codex-lane".
  (11, 't_chunk_fl3', 'forge-codex-lane', 'review', 1786234200, 1786234260,
   'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-6","project":"metadata-live-fixture","branch":"chunk/6-same-card","pr":"https://github.com/example/metadata-live-fixture/pull/6","lane":"forge-codex-lane","scenarios":{"added":3,"passing":3,"feature_files":["tests/features/chunk_6.feature"]},"check":{"green":true,"coverage_pct":100},"files_changed":4,"lines_changed":120,"decisions":[],"debt":[],"card_proposals":[],"docs_reconciled":[],"duration_min":15,"worker":"codex/gpt-5.6-luna xhigh"}'),
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
