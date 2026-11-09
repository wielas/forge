-- Anonymised triage board: 15 cards in the shape of a real run's follow-ups.
-- Real shapes (creators, timestamps, the CARD? prefix, comment counts, schema); every title,
-- body, comment and id is synthetic; the PR numbers (#99NN) and chunk numbers (CHUNK-9NN) are in ranges
-- no project has reached, so none can be mistaken for a real one. Built from a cp-snapshot, never the live board.
PRAGMA journal_mode=wal;
BEGIN TRANSACTION;
CREATE TABLE kanban_notify_subs (
    task_id       TEXT NOT NULL,
    platform      TEXT NOT NULL,
    chat_id       TEXT NOT NULL,
    thread_id     TEXT NOT NULL DEFAULT '',
    user_id       TEXT,
    user_id_alt   TEXT,
    chat_type     TEXT,
    notifier_profile TEXT,
    delivery_mode TEXT NOT NULL DEFAULT 'notify',
    delivery_metadata TEXT,
    created_at    INTEGER NOT NULL,
    last_event_id INTEGER NOT NULL DEFAULT 0, last_ping_event_id INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (task_id, platform, chat_id, thread_id)
);
CREATE TABLE task_attachments (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id      TEXT NOT NULL,
    filename     TEXT NOT NULL,
    stored_path  TEXT NOT NULL,
    content_type TEXT,
    size         INTEGER NOT NULL DEFAULT 0,
    uploaded_by  TEXT,
    created_at   INTEGER NOT NULL
);
CREATE TABLE task_comments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    TEXT NOT NULL,
    author     TEXT NOT NULL,
    body       TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
INSERT INTO "task_comments" VALUES(59,'t_tr04','default','Synthetic reviewer note on t_tr04: no project content.',1790162147);
INSERT INTO "task_comments" VALUES(62,'t_tr12','default','Synthetic reviewer note on t_tr12: no project content.',1790262131);
CREATE TABLE task_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    TEXT NOT NULL,
    run_id     INTEGER,
    kind       TEXT NOT NULL,
    payload    TEXT,
    created_at INTEGER NOT NULL
);
INSERT INTO "task_events" VALUES(1082,'t_tr02',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790161798);
INSERT INTO "task_events" VALUES(1083,'t_tr03',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790161798);
INSERT INTO "task_events" VALUES(1084,'t_tr01',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790161798);
INSERT INTO "task_events" VALUES(1085,'t_tr04',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790161910);
INSERT INTO "task_events" VALUES(1086,'t_tr04',NULL,'commented','{"author": "default", "len": 54}',1790162147);
INSERT INTO "task_events" VALUES(1089,'t_tr05',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790162485);
INSERT INTO "task_events" VALUES(1090,'t_tr06',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790162486);
INSERT INTO "task_events" VALUES(1091,'t_tr07',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790162486);
INSERT INTO "task_events" VALUES(1100,'t_tr08',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790259341);
INSERT INTO "task_events" VALUES(1101,'t_tr11',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790259353);
INSERT INTO "task_events" VALUES(1102,'t_tr10',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790259353);
INSERT INTO "task_events" VALUES(1103,'t_tr09',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790259353);
INSERT INTO "task_events" VALUES(1104,'t_tr14',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790260879);
INSERT INTO "task_events" VALUES(1105,'t_tr12',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790260879);
INSERT INTO "task_events" VALUES(1106,'t_tr15',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790260879);
INSERT INTO "task_events" VALUES(1107,'t_tr13',NULL,'created','{"assignee": null, "status": "triage", "parents": [], "creator_task_id": null, "tenant": null, "workspace_kind": "scratch", "workspace_path": null, "branch_name": null, "project_id": null, "skills": null, "goal_mode": null, "model_override": null, "provider_override": null}',1790260879);
INSERT INTO "task_events" VALUES(1108,'t_tr12',NULL,'commented','{"author": "default", "len": 54}',1790262131);
CREATE TABLE task_links (
    parent_id  TEXT NOT NULL,
    child_id   TEXT NOT NULL,
    PRIMARY KEY (parent_id, child_id)
);
CREATE TABLE task_runs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id             TEXT NOT NULL,
    profile             TEXT,
    step_key            TEXT,
    status              TEXT NOT NULL,
    -- status: running | done | blocked | crashed | timed_out | failed | released
    claim_lock          TEXT,
    claim_expires       INTEGER,
    worker_pid          INTEGER,
    max_runtime_seconds INTEGER,
    last_heartbeat_at   INTEGER,
    started_at          INTEGER NOT NULL,
    ended_at            INTEGER,
    outcome             TEXT,
    -- outcome: completed | blocked | crashed | timed_out | spawn_failed |
    --          gave_up | reclaimed | (null while still running)
    summary             TEXT,
    metadata            TEXT,
    error               TEXT
, worker_started_at INTEGER);
CREATE TABLE tasks (
    id                   TEXT PRIMARY KEY,
    title                TEXT NOT NULL,
    body                 TEXT,
    assignee             TEXT,
    status               TEXT NOT NULL,
    priority             INTEGER DEFAULT 0,
    created_by           TEXT,
    created_at           INTEGER NOT NULL,
    started_at           INTEGER,
    completed_at         INTEGER,
    workspace_kind       TEXT NOT NULL DEFAULT 'scratch',
    workspace_path       TEXT,
    branch_name          TEXT,
    -- Optional link to a first-class Project (hermes_cli/projects_db). When set,
    -- the task's worktree is anchored under the project's primary repo with a
    -- deterministic branch name instead of a random wt/<task-id> fallback.
    project_id           TEXT,
    claim_lock           TEXT,
    claim_expires        INTEGER,
    tenant               TEXT,
    result               TEXT,
    idempotency_key      TEXT,
    -- Unified consecutive-failure counter. Incremented on spawn
    -- failure, timeout, or crash; reset only on successful completion.
    -- The circuit breaker in _record_task_failure trips when this
    -- exceeds DEFAULT_FAILURE_LIMIT consecutive non-successes.
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    worker_pid           INTEGER,
    -- Short excerpt of the most recent failure's error text.
    last_failure_error   TEXT,
    max_runtime_seconds  INTEGER,
    last_heartbeat_at    INTEGER,
    -- Pointer into task_runs for the currently-active run (NULL if no
    -- run is in-flight). Denormalised for cheap reads.
    current_run_id       INTEGER,
    -- Forward-compat for v2 workflow routing. In v1 the kernel writes
    -- these when the task is opted into a template but otherwise ignores
    -- them; the dispatcher doesn't consult them for routing yet.
    workflow_template_id TEXT,
    current_step_key     TEXT,
    -- Force-loaded skills for the worker on this task, stored as JSON.
    -- Passed to the worker via `--skills`. NULL or empty array = no extras.
    skills               TEXT,
    -- Per-task model override. When set, the dispatcher passes -m <model>
    -- to the worker, overriding the profile's default model. NULL = use
    -- the profile default.
    model_override       TEXT,
    -- Provider the model override belongs to. When set (alongside
    -- model_override), the dispatcher passes --provider <name> so the
    -- worker resolves the model against the right backend instead of the
    -- profile's configured provider. NULL = profile provider.
    provider_override    TEXT,
    -- Per-task reasoning effort for the worker (minimal|low|medium|high|
    -- xhigh|max|ultra, or 'none' for thinking off). When set, the dispatcher
    -- passes --reasoning <level> so the worker runs at that depth regardless
    -- of the profile's agent.reasoning_effort. NULL = profile setting.
    reasoning_effort     TEXT,
    -- Per-task override for the consecutive-failure circuit breaker.
    -- The value is the failure count at which the breaker trips — e.g.
    -- ``max_retries=1`` blocks on the first failure. NULL (the common
    -- case) falls through to the dispatcher-level ``kanban.failure_limit``
    -- config and then ``DEFAULT_FAILURE_LIMIT``.
    max_retries          INTEGER,
    -- When 1, the dispatched worker runs in a Ralph-style goal loop: an
    -- auxiliary judge re-evaluates the worker's response against the
    -- card title/body after each turn and feeds a continuation prompt
    -- back into the SAME session until the judge agrees the work is done
    -- or ``goal_max_turns`` is exhausted. NULL/0 = classic single-shot
    -- worker (the default).
    goal_mode            INTEGER NOT NULL DEFAULT 0,
    -- Goal-loop turn budget for ``goal_mode`` workers. NULL = use the
    -- goals-engine default.
    goal_max_turns       INTEGER,
    -- Originating chat/agent session id when the task was created from
    -- inside an agent loop that propagated ``HERMES_SESSION_ID``. NULL
    -- for tasks created from the CLI, dashboard, or any path that doesn't
    -- set the env var. Indexed so per-session list queries stay cheap on
    -- larger boards.
    session_id           TEXT,
    -- Typed block reason set by ``block_task`` (one of VALID_BLOCK_KINDS, or
    -- NULL for legacy/un-typed blocks). Drives routing: ``dependency`` never
    -- sits in ``blocked`` (goes to ``todo`` for parent-gating); the others go
    -- to ``blocked`` for a human. Preserved across unblock so a re-block for
    -- the SAME kind can be recognised as a loop.
    block_kind           TEXT,
    -- Unblock-loop counter. Incremented each time a task is re-blocked for the
    -- same truly-blocked reason after having been unblocked. When it reaches
    -- BLOCK_RECURRENCE_LIMIT the task is routed to ``triage`` instead of
    -- ``blocked`` so a cron can't spin it forever. Reset to 0 only on a
    -- successful completion — NOT on unblock (resetting on unblock is exactly
    -- the amnesia that let the loop run unbounded).
    block_recurrences    INTEGER NOT NULL DEFAULT 0
, completion_contract TEXT, worker_started_at INTEGER);
INSERT INTO "tasks" VALUES('t_tr02','CARD?: Synthetic follow-up 02: topic B','This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790161798,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr03','CARD?: Synthetic follow-up 03: topic C','This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790161798,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr01','CARD?: Synthetic follow-up 01: topic A','This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790161798,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr04','CARD?: Synthetic follow-up 04: topic D','This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790161910,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr05','CARD?: Synthetic follow-up 05: topic E','This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790162485,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr06','CARD?: Synthetic follow-up 06: topic F','This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790162486,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr07','CARD?: Synthetic follow-up 07: topic G','This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'forge-operator',1790162486,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,NULL,NULL);
INSERT INTO "tasks" VALUES('t_tr08','Synthetic follow-up 08: topic H','Raised by the reviewer of PR #9908 (CHUNK-908). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790259341,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr11','Synthetic follow-up 11: topic K','Raised by the reviewer of PR #9911 (CHUNK-911). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790259353,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr10','Synthetic follow-up 10: topic J','Raised by the reviewer of PR #9910 (CHUNK-910). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790259353,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr09','Synthetic follow-up 09: topic I','Raised by the reviewer of PR #9909 (CHUNK-909). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790259353,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr14','Synthetic follow-up 14: topic N','Raised by the reviewer of PR #9914 (CHUNK-914). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790260879,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr12','Synthetic follow-up 12: topic L','Raised by the reviewer of PR #9912 (CHUNK-912). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790260879,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr15','Synthetic follow-up 15: topic O','Raised by the reviewer of PR #9915 (CHUNK-915). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790260879,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
INSERT INTO "tasks" VALUES('t_tr13','Synthetic follow-up 13: topic M','Raised by the reviewer of PR #9913 (CHUNK-913). This synthetic card stands in for a real follow-up; the text carries no project content. This synthetic card stands in for a real follow-up; the text carries no project content.',NULL,'triage',0,'user',1790260879,NULL,NULL,'scratch',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,0,'local-only',NULL);
CREATE INDEX idx_tasks_assignee_status ON tasks(assignee, status);
CREATE INDEX idx_tasks_status          ON tasks(status);
CREATE INDEX idx_links_child           ON task_links(child_id);
CREATE INDEX idx_links_parent          ON task_links(parent_id);
CREATE INDEX idx_comments_task         ON task_comments(task_id, created_at);
CREATE INDEX idx_events_task           ON task_events(task_id, created_at);
CREATE INDEX idx_runs_task             ON task_runs(task_id, started_at);
CREATE INDEX idx_runs_status           ON task_runs(status);
CREATE INDEX idx_attachments_task      ON task_attachments(task_id, created_at);
CREATE INDEX idx_notify_task           ON kanban_notify_subs(task_id);
CREATE INDEX idx_tasks_tenant ON tasks(tenant);
CREATE INDEX idx_tasks_idempotency ON tasks(idempotency_key);
CREATE INDEX idx_tasks_session_id ON tasks(session_id);
CREATE INDEX idx_events_run ON task_events(run_id, id);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('task_events',1117);
INSERT INTO "sqlite_sequence" VALUES('task_runs',71);
INSERT INTO "sqlite_sequence" VALUES('task_comments',65);
COMMIT;
