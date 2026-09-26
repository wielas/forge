-- Fixture board for scripts/metrics.sh in the shape the epic's flow leaves
-- behind (ADR-0019): ONE card per chunk, same-card review, recommend-only.
--
-- It is a second board rather than more rows in metrics-board.sql because the
-- two are different eras of the same log, and their numbers answer different
-- questions. metrics-board.sql is the child-card era — a prejudge card and a
-- judge card hanging off each chunk — and its exact expectation already pins
-- every bucket that era can reach. This board is what run A will produce, and
-- the epic's north-star numbers (GW6) are computed from it.
--
-- WHAT IS DIFFERENT, AND WHY EACH ROW IS HERE.
--
--   * The chunk envelope (`forge.chunk.v1`) rides a `review_requested` run,
--     never a `completed` one: the lane hands off with `request-review` (FL3).
--     Epic P4: every reader that filtered on `outcome = 'completed'` saw zero
--     chunk envelopes on a board like this one. t_cb carries TWO such runs —
--     one before a bounce, one after — because the lane re-enters the same card.
--
--   * The verdict lives on the chunk's OWN card. The verifier's completion runs
--     are `forge-verifier` runs on t_ca/t_cb/t_cc themselves, so a verdict is
--     attributed to its card without walking a task_link, and a
--     `forge.judge.v1` completion on a chunk card must NOT be counted as a
--     malformed chunk envelope (the `neither` bucket).
--
--   * Who merged is in `tasks.result`, which two producers write:
--       `merged by forge-verifier: …`            merge mode (prejudge-review.sh route_merge)
--       `merged: <pr> as <sha> (completed by merge-watcher…)`  the operator merged on
--                                                GitHub and the watcher completed it
--     t_cb is the verifier's merge, t_ca and t_cc the operator's.
--
--   * t_cc is a HUMAN-tier chunk: no forge-codex-lane run at all. Its handoff
--     came from an interactive session through lane-handoff.sh, so its
--     `review_requested` run has no lane profile — it is identified as a chunk
--     by that run alone.
--
--   * t_cd is in review and t_ce is held for a merge: neither is done, so
--     neither is a merged chunk — but both are cards, and so is t_tr, a
--     follow-up in triage. Cards per chunk counts all six over the three
--     chunks created and finished here.
--
--   * One comment is the merge-watcher's FORGE-WATCHER-NOTIFIED marker, written
--     from cron as the host's default profile. It is not an operator action, and
--     `default` never ran on this board, so the author test alone would count it.
--
-- Every timestamp sits inside 2026-07-28 (1785200000 onwards), like the
-- child-card fixture, so a --since/--until window takes all of it or none.
PRAGMA journal_mode=wal;

CREATE TABLE tasks (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    assignee     TEXT,
    status       TEXT NOT NULL,
    result       TEXT,
    created_at   INTEGER NOT NULL,
    completed_at INTEGER
);
CREATE TABLE task_runs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    TEXT NOT NULL,
    profile    TEXT,
    status     TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    ended_at   INTEGER,
    outcome    TEXT,
    metadata   TEXT
);
CREATE TABLE task_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    TEXT NOT NULL,
    kind       TEXT NOT NULL,
    payload    TEXT,
    created_at INTEGER NOT NULL
);
CREATE TABLE task_comments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    TEXT NOT NULL,
    author     TEXT NOT NULL,
    body       TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE task_links (
    parent_id TEXT NOT NULL,
    child_id  TEXT NOT NULL,
    PRIMARY KEY (parent_id, child_id)
);

INSERT INTO tasks (id, title, assignee, status, result, created_at, completed_at) VALUES
  ('t_ca', 'CHUNK-1: merged by the operator', 'forge-verifier', 'done',
   'merged: https://example/pull/1 as abcdef123456 (completed by merge-watcher)', 1785200000, 1785207300),
  ('t_cb', 'CHUNK-2: bounced once, then merged by the verifier', 'forge-verifier', 'done',
   'merged by forge-verifier: approve 3/3/3', 1785200000, 1785219000),
  ('t_cc', 'CHUNK-3: implemented by hand', 'forge-verifier', 'done',
   'merged: https://example/pull/3 as 111111111111 (completed by merge-watcher)', 1785200000, 1785208800),
  ('t_cd', 'CHUNK-4: in review', 'forge-verifier', 'review', NULL, 1785200000, NULL),
  ('t_ce', 'CHUNK-5: held for the operator''s merge', 'forge-verifier', 'blocked', NULL, 1785200000, NULL),
  ('t_tr', 'follow-up: a verifier nit', NULL, 'triage', NULL, 1785200000, NULL);

INSERT INTO task_links (parent_id, child_id) VALUES ('t_ca', 't_cd');

-- The implementers' handoffs. worker_session_id is deliberately absent: the
-- driver join is pinned by the child-card fixture, and here an absent id is
-- simply "unjudged", which keeps this expectation free of profile state.
INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome, metadata) VALUES
  ('t_ca','forge-codex-lane','review_requested',1785200010,1785200100,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-1","pr":"https://example/pull/1","codex_model":"gpt-5.6-luna","codex_reasoning_effort":"xhigh","codex_model_source":"rollout"}'),
  ('t_cb','forge-codex-lane','review_requested',1785201000,1785201600,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-2","pr":"https://example/pull/2","codex_model":"gpt-5.6-luna","codex_reasoning_effort":"xhigh","codex_model_source":"rollout"}'),
  ('t_cb','forge-codex-lane','review_requested',1785210000,1785210600,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-2","pr":"https://example/pull/2","codex_model":"gpt-5.6-luna","codex_reasoning_effort":"xhigh","codex_model_source":"rollout"}'),
  ('t_cc',NULL,'review_requested',1785204000,1785205200,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-3","pr":"https://example/pull/3"}'),
  ('t_cd','forge-codex-lane','review_requested',1785211000,1785211600,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-4","pr":"https://example/pull/4","codex_model":"gpt-5.6-luna","codex_reasoning_effort":"xhigh","codex_model_source":"rollout"}');

-- The verifier, on the same cards. A hold and a bounce carry no envelope
-- (`block` and `request-changes` take no --metadata); the verdict reaches a run
-- on the completion — the merge-watcher's for t_ca/t_cc, the verifier's own
-- merge for t_cb.
INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome, metadata) VALUES
  ('t_ca','forge-verifier','blocked',1785200110,1785200200,'blocked',NULL),
  ('t_ca','forge-verifier','done',1785207300,1785207300,'completed',
   '{"schema":"forge.judge.v1","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":3,"architectural_conformance":3,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3}}'),
  ('t_cb','forge-verifier','changes_requested',1785201700,1785201800,'changes_requested',NULL),
  ('t_cb','forge-verifier','done',1785210700,1785219000,'completed',
   '{"schema":"forge.judge.v1","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":3,"architectural_conformance":3,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3}}'),
  ('t_cc','forge-verifier','blocked',1785205300,1785205400,'blocked',NULL),
  ('t_cc','forge-verifier','done',1785208800,1785208800,'completed',
   '{"schema":"forge.judge.v1","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":2,"architectural_conformance":3,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3}}'),
  ('t_ce','forge-verifier','blocked',1785212000,1785212100,'blocked',NULL);

-- PR open is the FIRST review_requested event (the lane hands off right after
-- `gh pr create`, and a bounce re-enters the same PR); merged is the completed
-- event. t_ca 2 h, t_cb 5 h, t_cc 1 h: median 2.00, max 5.00.
INSERT INTO task_events (task_id, kind, payload, created_at) VALUES
  ('t_ca','review_requested',NULL,1785200100),
  ('t_ca','blocked','{"reason":"merge-pending: CHUNK-1 is verified and NOT merged","kind":"needs_input"}',1785200200),
  ('t_ca','completed',NULL,1785207300),
  ('t_cb','review_requested',NULL,1785201000),
  ('t_cb','changes_requested',NULL,1785201800),
  ('t_cb','review_requested',NULL,1785210000),
  ('t_cb','completed',NULL,1785219000),
  ('t_cc','review_requested',NULL,1785205200),
  ('t_cc','blocked','{"reason":"merge-pending: CHUNK-3 is verified and NOT merged","kind":"needs_input"}',1785205400),
  ('t_cc','completed',NULL,1785208800),
  ('t_cd','review_requested',NULL,1785211600),
  ('t_ce','blocked','{"reason":"merge-pending: CHUNK-5 is verified and NOT merged","kind":"capability"}',1785212100),
  ('t_ce','unblocked',NULL,1785212500),
  ('t_ce','blocked','{"reason":"merge-pending: CHUNK-5 is verified and NOT merged","kind":"needs_input"}',1785213000);

INSERT INTO task_comments (task_id, author, body, created_at) VALUES
  ('t_ca','forge-codex-lane','PR opened',1785200090),
  ('t_cb','wielas','the retry loop is wrong; see line 40',1785201900),
  ('t_ce','default','FORGE-WATCHER-NOTIFIED closed https://example/pull/5 (hold 1)
https://example/pull/5 was CLOSED without merging',1785212200);
