-- Fixture board for scripts/digest.sh (epic GW2). The digest case reads this
-- board beside metrics-board-fl3.sql, a quiet board and an archived one, with
-- TZ=UTC and --day 2026-07-28, and diffs the whole message against
-- scripts/fixtures/digest-expected.txt.
--
-- The three blocked cards are the three shapes "waiting on you" must render in
-- GW1's decision-first format:
--   t_d1  a verifier hold, whose reason ALREADY is the format. It is shown as
--         written up to the end of its reply; the evidence after it is on the
--         card, not in a phone message.
--   t_d2  a lane block: one `<class>: <reason>` line, expanded from the class
--         table in scripts/decision-message.sh.
--   t_d3  a reason outside the registry — the child-card era wrote these — which
--         is rendered as `other` with its whole line as the headline, never
--         dropped.
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

-- t_d6 landed on 2026-07-28 (UTC); t_d7 landed the day before and must not
-- appear under "landed" at all.
INSERT INTO tasks (id, title, assignee, status, result, created_at, completed_at) VALUES
  ('t_d1', 'CHUNK-7: Sync engine',  'forge-verifier',   'blocked', NULL, 1785200000, NULL),
  ('t_d2', 'CHUNK-8: Exporter',     'forge-codex-lane', 'blocked', NULL, 1785200000, NULL),
  ('t_d3', 'CHUNK-9: CLI',          NULL,               'blocked', NULL, 1785200000, NULL),
  ('t_d4', 'CHUNK-10: Docs',        'forge-codex-lane', 'running', NULL, 1785200000, NULL),
  ('t_d5', 'CHUNK-11: API',         'forge-codex-lane', 'todo',    NULL, 1785200000, NULL),
  ('t_d6', 'CHUNK-6: Model',        'forge-verifier',   'done',
   'merged: https://example/pull/6 as abcdef123456 (completed by merge-watcher)', 1785200000, 1785210000),
  ('t_d7', 'CHUNK-5: Schema',       'forge-verifier',   'done',
   'merged: https://example/pull/5 as 222222222222 (completed by merge-watcher)', 1785100000, 1785110000);

INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome, metadata) VALUES
  ('t_d6','forge-codex-lane','review_requested',1785201000,1785201600,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-6","pr":"https://example/pull/6"}'),
  ('t_d1','forge-codex-lane','review_requested',1785202000,1785202600,'review_requested',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-7","pr":"https://example/pull/7"}');

INSERT INTO task_events (task_id, kind, payload, created_at) VALUES
  -- An EARLIER block on t_d2 that was lifted: the digest shows the LAST one.
  ('t_d2','blocked','{"reason":"ci-red: make check is red after codex","kind":"needs_input"}',1785203000),
  ('t_d2','unblocked',NULL,1785204000),
  ('t_d2','blocked','{"reason":"env: codex usage limit — waited past FORGE_QUOTA_MAX_WAIT (park record: .forge/park-1.json)","kind":"needs_input"}',1785205000),
  ('t_d3','blocked','{"reason":"tier-2 operator review required: run /judge, then merge or bounce","kind":"needs_input"}',1785205100),
  ('t_d1','blocked','{"reason":"merge-pending: CHUNK-7: Sync engine is verified and NOT merged — the verifier may only recommend\n\nWhat it means: the deterministic gate is clear, `make check` is green on this branch merged with main, and the scorer reached approve 3/3/3. Recommend-only is the default until the flip criterion is met (ADR-0019 D19.3)\nDecision needed: merge the PR, or send it back\nRisk: nothing is merged and this card''s children stay held until it is\nReply: merge https://example/pull/7 on GitHub — the merge-watcher completes this card — or `~/.forge/repo/scripts/bounce.sh t_d1 \"<reason>\" --board digest-fixture`\n\n### Evidence\n- gate: clear, 0 blocks\n- merged tree: make check green","kind":"needs_input"}',1785206000),
  ('t_d6','completed',NULL,1785210000);
