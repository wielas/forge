-- Fixture board for the checkpoint (scripts/checkpoint.sh, epic S8). Checked in
-- as SQL, never as a .db. The schema is metrics-board.sql's — the columns the
-- live Hermes schema uses that metrics.sh and checkpoint.sh read — and WAL, like
-- every Hermes board.
--
-- One milestone, M1, five chunk cards and a held gate, in the shape of the
-- Squatfather's own GATE-M1 and CHUNK-N cards (the bodies are abridged, with the
-- lines the checkpoint reads kept verbatim in form):
--   - the gate's `Delivers:` runs on into a second sentence ("It also lays ...")
--     that names requirements finished in a LATER milestone;
--   - a chunk's `Serves:` shares its line with `Relevant ADRs:`;
--   - NFR-2 contains the letters FR-2 and must not read as FR-2;
--   - FR-9 is named in Delivers and served by no chunk: unserved.
-- Two follow-ups wait in triage, and CHUNK-6 of M2 waits on the gate.
-- Tests turn single facts with UPDATE on a copy: the gate's Estimate, a chunk's
-- status, the probe's project.
PRAGMA journal_mode=wal;

CREATE TABLE tasks (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    assignee     TEXT,
    status       TEXT NOT NULL,
    result       TEXT,
    created_at   INTEGER NOT NULL,
    completed_at INTEGER,
    body         TEXT
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

INSERT INTO tasks (id, title, body, assignee, status, created_at, completed_at) VALUES
  ('t_c1', 'CHUNK-1: Store owner history', '### CHUNK-1: Store owner history
- **Goal:** Persist the profile.
- **Milestone:** M1  ·  **Depends on:** none
- **Serves:** FR-6, FR-7, NFR-2  ·  **Relevant ADRs:** 0002, 0004
- **Lane:** forge-codex-lane  ·  **Risk:** med', NULL, 'done', 1785200000, 1785200100),
  ('t_c2', 'CHUNK-2: Read the watch', '### CHUNK-2: Read the watch
- **Goal:** Pull sessions.
- **Milestone:** M1  ·  **Depends on:** CHUNK-1
- **Serves:** FR-8, FR-18  ·  **Relevant ADRs:** 0003
- **Lane:** forge-codex-lane  ·  **Risk:** med', NULL, 'done', 1785200000, 1785200200),
  ('t_c3', 'CHUNK-3: Plan a week', '### CHUNK-3: Plan a week
- **Goal:** Plan.
- **Milestone:** M1  ·  **Depends on:** CHUNK-1
- **Serves:** FR-8  ·  **Relevant ADRs:** 0004
- **Lane:** forge-codex-lane  ·  **Risk:** med', NULL, 'done', 1785200000, 1785200300),
  ('t_c4', 'CHUNK-4: Guard every payload', '### CHUNK-4: Guard every payload
- **Goal:** Guard.
- **Milestone:** M1  ·  **Depends on:** CHUNK-2, CHUNK-3
- **Serves:** NFR-3  ·  **Relevant ADRs:** 0004
- **Lane:** forge-codex-lane  ·  **Risk:** med', NULL, 'done', 1785200000, 1785200400),
  ('t_c5', 'CHUNK-5: Decide the spike', '### CHUNK-5: Decide the spike
- **Goal:** Decide.
- **Milestone:** M1  ·  **Depends on:** CHUNK-2, CHUNK-3
- **Serves:** NFR-6  ·  **Relevant ADRs:** 0003
- **Lane:** claude-interactive  ·  **Risk:** low', NULL, 'done', 1785200000, 1785200500),
  ('t_g1', 'GATE-M1: Milestone 1 — the offline core', '### GATE-M1: Milestone 1 — the offline core
- **Milestone:** M1
- **Delivers:** FR-8, FR-18, FR-9, NFR-2, NFR-3, NFR-6. It also lays the offline rules that FR-1, FR-5 and FR-7 finish in M2 or M3.
- **Probe:** tests/probes/gate_m1.json
- **Estimate:** 5 chunks
- **Lane:** claude-interactive', 'forge-operator-handoff', 'blocked', 1785200000, NULL),
  ('t_c6', 'CHUNK-6: Push the plan', '### CHUNK-6: Push the plan
- **Goal:** Push.
- **Milestone:** M2  ·  **Depends on:** GATE-M1
- **Serves:** FR-1  ·  **Relevant ADRs:** 0004
- **Lane:** forge-codex-lane  ·  **Risk:** med', 'forge-codex-lane', 'todo', 1785200000, NULL),
  ('t_f1', 'follow-up: tighten the history window', NULL, NULL, 'triage', 1785200600, NULL),
  ('t_f2', 'follow-up: name the weekday type', NULL, NULL, 'triage', 1785200700, NULL);
INSERT INTO task_links (parent_id, child_id) VALUES
  ('t_c1', 't_g1'), ('t_c2', 't_g1'), ('t_c3', 't_g1'), ('t_c4', 't_g1'), ('t_c5', 't_g1'),
  ('t_g1', 't_c6');
