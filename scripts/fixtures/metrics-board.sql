-- Fixture board for scripts/metrics.sh. Checked in as SQL, never as a .db:
-- a binary in git is a number nobody can review, which is the failure this
-- whole slice exists to end.
--
-- The columns below are the ones metrics.sh reads, with the names and NOT NULL
-- constraints the live Hermes schema uses. verify.sh's metrics/live-schema-has
-- -fixture-columns case checks that claim against a real board rather than
-- trusting this comment.
--
-- Every bucket the script can report is populated here on purpose, including
-- the ones that only appear when something is wrong: a chunk run with no
-- envelope at all, a verdict that cannot be attributed to a chunk card, a
-- noncanonical judge envelope that must NOT be counted, and a block reason
-- whose leading token is not in the documented vocabulary.
--
-- WAL, because every Hermes board is `journal_mode=wal` and this fixture was
-- `delete` — SQLite's default — for its whole life. That one unstated
-- difference is why a 54-case suite could not see F47: `mode=ro` fails only on
-- a WAL database with no `-shm` beside it, so the bug was unreachable from this
-- fixture no matter how many cases were pointed at it. A fixture that differs
-- from production in a property nobody wrote down certifies the wrong thing;
-- journal mode is now part of what it reproduces.
PRAGMA journal_mode=wal;

CREATE TABLE tasks (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    status       TEXT NOT NULL,
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

-- 1785200000 is 2026-07-28; every row sits inside one day so a --since/--until
-- window either takes the whole board or none of it.
INSERT INTO tasks (id, title, status, created_at, completed_at) VALUES
  ('t_c1', 'CHUNK-1: flat envelope',            'done', 1785200000, 1785200100),
  ('t_c2', 'CHUNK-2: nested envelope',          'done', 1785200000, 1785200200),
  ('t_c3', 'CHUNK-3: no envelope at all',       'done', 1785200000, 1785200300),
  ('t_p1', 'prejudge: CHUNK-1',                 'done', 1785200100, 1785200110),
  ('t_p2', 'prejudge: CHUNK-2',                 'done', 1785200200, 1785200210),
  ('t_p3', 'prejudge: CHUNK-3 (noncanonical)',  'done', 1785200300, 1785200310),
  ('t_j1', 'judge: CHUNK-1',                    'done', 1785200120, 1785200130),
  ('t_j2', 'judge: CHUNK-1 re-review',          'done', 1785200140, 1785200150),
  ('t_j3', 'judge: CHUNK-2',                    'done', 1785200220, 1785200230),
  ('t_j4', 'judge: orphan, linked to nothing',  'done', 1785200240, 1785200250),
  ('t_b1', 'blocked card',                      'blocked', 1785200400, NULL);

-- t_j2 hangs off the TIER-1 card, not the chunk card. That really happens on
-- forge-ladder (t_26565597), and it is why attribution walks two hops.
INSERT INTO task_links (parent_id, child_id) VALUES
  ('t_c1', 't_p1'), ('t_c2', 't_p2'), ('t_c3', 't_p3'),
  ('t_c1', 't_j1'), ('t_p1', 't_j2'), ('t_c2', 't_j3');

-- Chunk completions. t_c3 has no prejudge child, so it is only identifiable by
-- its forge-codex-lane run — and its metadata carries neither envelope shape,
-- which must still leave it inside the denominator.
INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome, metadata) VALUES
  ('t_c1','forge-codex-lane','done',1785200010,1785200100,'completed',
   '{"schema":"forge.chunk.v1","chunk_id":"CHUNK-1","pr":"https://example/pull/1"}'),
  ('t_c2','forge-codex-lane','done',1785200110,1785200200,'completed',
   '{"forge.chunk.v1":{"chunk_id":"CHUNK-2","pr":"https://example/pull/2"},"tests_run":9}'),
  ('t_c3','forge-codex-lane','done',1785200210,1785200300,'completed',
   '{"changed_files":["a.py"],"tests_run":4}');

-- Tier 1 is the forge-prejudge profile. Tier 2 is everything else, including
-- the unassigned cards an operator drives by hand (profile NULL).
INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome, metadata) VALUES
  ('t_p1','forge-prejudge','done',1785200105,1785200110,'completed',
   '{"schema":"forge.judge.v1","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":3,"architectural_conformance":3,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3}}'),
  ('t_p2','forge-prejudge','done',1785200205,1785200210,'completed',
   '{"schema":"forge.judge.v1","verdict":"bounce","scores":{"spec_fidelity":1,"scenario_integrity":2,"architectural_conformance":1,"scope_discipline":2,"debt_honesty":2,"doc_reconciliation":2}}'),
  -- The CI-red incident's one-off keys (audit F3). Not forge.judge.v1, so the
  -- real bounce it records is invisible to every number here. That is the
  -- finding, and the fixture keeps it visible instead of quietly counting it.
  ('t_p3','forge-prejudge','done',1785200305,1785200310,'completed',
   '{"forge.prejudge.v1.verdict":"bounce","forge.prejudge.v1.reason":"ci red"}'),
  ('t_j1',NULL,'done',1785200125,1785200130,'completed',
   '{"schema":"forge.judge.v1","verdict":"bounce","scores":{"spec_fidelity":1,"scenario_integrity":1,"architectural_conformance":1,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3}}'),
  ('t_j2',NULL,'done',1785200145,1785200150,'completed',
   '{"schema":"forge.judge.v1","verdict":"approve","scores":{"spec_fidelity":3,"scenario_integrity":3,"architectural_conformance":2,"scope_discipline":3,"debt_honesty":3,"doc_reconciliation":3}}'),
  ('t_j3',NULL,'done',1785200225,1785200230,'completed',
   '{"schema":"forge.judge.v1","verdict":"bounce","scores":{"spec_fidelity":0,"scenario_integrity":1,"architectural_conformance":2,"scope_discipline":1,"debt_honesty":2,"doc_reconciliation":2}}'),
  ('t_j4',NULL,'done',1785200245,1785200250,'completed',
   '{"schema":"forge.judge.v1","verdict":"bounce","scores":{"spec_fidelity":1,"scenario_integrity":1,"architectural_conformance":1,"scope_discipline":1,"debt_honesty":1,"doc_reconciliation":1}}');

-- forge.block.v1 is absent because it cannot exist: kanban_block takes no
-- metadata parameter (audit F26). The class is the leading token of the
-- free-text reason, and only some of these have one.
INSERT INTO task_events (task_id, kind, payload, created_at) VALUES
  ('t_b1','blocked','{"reason":"failing-prereq: parent PR #1 is OPEN, not merged","kind":"needs_input"}',1785200400),
  ('t_b1','blocked','{"reason":"failing-prereq: parent PR #2 is OPEN, not merged","kind":"needs_input"}',1785200410),
  ('t_b1','blocked','{"reason":"gate-misrouted: tier-2 card dispatched to a lane","kind":"needs_input"}',1785200420),
  ('t_b1','blocked','{"reason":"review-required: CHUNK-1 PR #1 — three fixes applied","kind":"needs_input"}',1785200430),
  ('t_b1','blocked','{"reason":"tier-2 operator review required: run /judge, then merge or bounce","kind":"needs_input"}',1785200440),
  ('t_b1','unblocked',NULL,1785200450),
  ('t_b1','unblocked',NULL,1785200460),
  ('t_c1','promoted',NULL,1785200005);

INSERT INTO task_comments (task_id, author, body, created_at) VALUES
  ('t_c1','forge-codex-lane','PR opened',                 1785200090),
  ('t_c1','forge-prejudge','approve, 3/3 across the board',1785200108),
  ('t_c1','wielas','merging by hand after review',         1785200160),
  ('t_c2','default','unblocking this from the CLI',        1785200470);
