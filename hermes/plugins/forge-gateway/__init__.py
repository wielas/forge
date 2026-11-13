"""forge-gateway: Forge's paired gateway (epic GW3, S8d).

THE GATEWAY IS A DEDICATED BOT. Owner ruling, 2026-11-11: the gate verbs are typed to a Telegram bot of their own, bound to
the Hermes profile `forge-gate`, whose toolset is EMPTY. The owner's main Telegram agent keeps its tools. This plugin does
two things, and the first only answers on that profile.

1. THREE SLASH COMMANDS, `/accept`, `/redirect` and `/park`, each a handler that calls exactly one
   allowlisted forge script with `--board` (scripts/gate-accept.sh, gate-redirect.sh, gate-park.sh,
   reached through `~/.forge/repo/scripts/`). A handler checks the sender ITSELF, never raises, and is
   idempotent on (chat_id, message_id). It is a program in a hot path: it holds no methodology, and the
   decision it enforces (what a phone may do to a milestone gate) is in the scripts and in
   docs/epic-hands-free.md (GW3).

   THE SENDER. The platform must be telegram, the chat a direct message, and the user id and the chat id
   both exactly `FORGE_OPERATOR_TELEGRAM_ID` (set in ~/.hermes/.env; unset refuses everything). A gateway
   that is open to everyone (`*` in an allowlist, or an allow-all flag, in the profile's own scope or the process's)
   refuses too: the paired chat is the only way in and an open door beside it voids the pairing.
   THE PROFILE. The session's profile (HERMES_SESSION_PROFILE) must be `forge-gate`. The paired operator who sends a verb
   to any other bot is answered `refused: send gate verbs to the forge-gate bot` and nothing runs. The plugin is
   enabled in the forge-gate profile (where it answers) and in the root profile (where it only refuses, so that a
   verb typed to the main bot never reaches a model that has a shell).

   THE LEDGER. `<state root>/gateway/ledger/<chat>-<message>.json` is created O_EXCL after the sender and the
   syntax are checked and BEFORE the script runs. A second delivery of the same message finds it, writes
   nothing and returns the first reply. That is at-most-once: a run that failed is retried by sending the
   verb again as a NEW message. pre_gateway_dispatch cannot hold this check: it is not called on the busy
   path (docs/hermes-field-notes.md).

2. A `pre_tool_call` GUARD. On a forge-gate turn it refuses EVERY tool call but a board read, a second wall behind the empty
   toolset. On any other messaging session that is not a kanban worker it is defence in depth, and only a tripwire: it
   refuses the tool calls that could write a board: `terminal`, `execute_code` and `process_manage` text that names
   `kanban` with a verb outside a read list or names the board file, every `kanban_*` tool but the readers, the file tools
   aimed at forge's own state, scripts, plugins, config or board directories (a relative path is placed the way Hermes
   places it, a patch is read with Hermes' own V4A parser, paths are compared case-insensitively, and a path that cannot
   be placed or a patch that cannot be read is refused), and `cronjob_manage` with a script. A plugin hook fails CLOSED
   when it raises or times out, so the guard catches everything itself and, on an internal error, blocks exactly those
   tools and passes the rest. `sqlite3`, `python -c` with a built-up string, a backslash-newline splitting the word
   `kanban`, and a sub-process bypass the text match; the main agent also has the gateway's built-in `/kanban ...` command.
   THE ARMING FILE IS AN OPERATOR SWITCH, NOT A SECURITY BOUNDARY: any agent running as the owner with a shell or file tool
   can write it. What stops a chat message from releasing a gate is that the only bot that answers the verbs has no tools.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import signal
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("forge_gateway")

LEDGER_SCHEMA = "forge.gateway-ledger.v1"

# THE PAIRED GATEWAY IS A DEDICATED BOT, bound to the profile `forge-gate` (owner ruling, 2026-11-11). The owner's main
# Telegram agent keeps its tools; the gate verbs run only on this profile's bot, whose toolset is empty.
GATE_PROFILE = "forge-gate"
WRONG_BOT_REPLY = "refused: send gate verbs to the forge-gate bot"

# THE ALLOWLIST. A constant of three entries; nothing below builds a script name from the typed text.
VERB_SCRIPTS: Dict[str, str] = {
    "accept": "gate-accept.sh",
    "redirect": "gate-redirect.sh",
    "park": "gate-park.sh",
}
_TEXT_REQUIRED = frozenset({"redirect"})
_ARGS_HINT = {
    "accept": "<board> <GATE-id> [why]",
    "redirect": "<board> <GATE-id> <text>",
    "park": "<board> <GATE-id> [why]",
}
_DESCRIPTION = {
    "accept": "Complete a held milestone gate (paired chat only; the gate must be armed apply)",
    "redirect": "Record what to change at a held milestone gate (paired chat only)",
    "park": "Stop and leave a milestone gate held (paired chat only)",
}

TIMEOUT_S = 25
_REPLY_CAP = 1500
_BOARD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_GATE_RE = re.compile(r"^GATE-[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
_USER_ID_RE = re.compile(r"^[0-9]{1,15}$")
_MESSAGE_ID_RE = re.compile(r"^[0-9]{1,18}$")
_CHAT_ID_RE = re.compile(r"^-?[0-9]{1,18}$")
_TEXT_MAX = 1000
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
_TRUTHY = frozenset({"1", "true", "yes", "on"})

# What the child script's environment keeps. The gateway process holds every API key in its environment
# (it loads ~/.hermes/.env at import); a gate script needs none of them.
_ENV_KEEP = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
             "HERMES_HOME", "HERMES_KANBAN_HOME", "FORGE_STATE_ROOT")
# A hook for tests: variables added to the child's environment. Never read from the process environment.
_EXTRA_ENV: Dict[str, str] = {}


# ---------------------------------------------------------------------------
# Seams. Hermes is imported lazily and only here, so everything below runs under a plain python3
# (CI has no Hermes), and a test replaces these two names.
# ---------------------------------------------------------------------------
def _session_env(name: str) -> str:
    from gateway.session_context import get_session_env
    return get_session_env(name, "") or ""


def _gateway_engaged() -> bool:
    try:
        from gateway.session_context import session_context_engaged
        return bool(session_context_engaged())
    except Exception:
        return False


def _home() -> str:
    return os.path.expanduser("~")


def _state_root() -> str:
    # The same formula as scripts/forge-state.sh forge_state_root (a verify case compares them).
    return os.environ.get("FORGE_STATE_ROOT") or os.path.join(_home(), ".forge")


def _forge_repo() -> str:
    return os.environ.get("FORGE_REPO") or os.path.join(_home(), ".forge", "repo")


# ---------------------------------------------------------------------------
# The sender
# ---------------------------------------------------------------------------
def _scoped_env(name: str) -> str:
    """The value of a gate variable in the ACTIVE PROFILE's secret scope: under a multiplexed gateway a profile's own
    `.env` is not in os.environ (gateway/platforms/_shared.py platform_gate_env). Without Hermes (CI), os.environ.
    With Hermes present but the accessor gone, it raises, so the caller refuses: a gate variable that cannot be read
    is not "unset"."""
    try:
        import gateway.session_context  # noqa: F401 - are we inside Hermes at all?
    except Exception:
        return os.environ.get(name, "")
    from gateway.platforms._shared import platform_gate_env
    return platform_gate_env(name)


def _allow_all_problem() -> Optional[str]:
    """An open door beside the pairing voids it. Both views are read, the profile's scope and the process: a `*` in
    either is a problem."""
    for key in ("TELEGRAM_ALLOWED_USERS", "GATEWAY_ALLOWED_USERS"):
        for value in (_scoped_env(key), os.environ.get(key, "")):
            if "*" in [x for x in re.split(r"[\s,]+", value) if x]:
                return f"{key} holds *"
    for key in ("TELEGRAM_ALLOW_ALL_USERS", "GATEWAY_ALLOW_ALL_USERS"):
        for value in (_scoped_env(key), os.environ.get(key, "")):
            if value.strip().lower() in _TRUTHY:
                return f"{key} is on"
    return None


def _session_profile() -> str:
    """The profile the session belongs to: HERMES_SESSION_PROFILE, which the gateway binds from `source.profile`
    (run.py `_set_session_env`), which `build_source` stamps with the profile that owns the receiving bot
    (gateway/platforms/base.py build_source, `set_owner_profile` from run_adapters.py `_configure_profile_adapter`).
    Empty for the default profile's own bot."""
    return _session_env("HERMES_SESSION_PROFILE").strip().lower()


def _sender_problem() -> Optional[str]:
    """None when the message comes from the paired chat; otherwise a short reason for the log. (The profile is judged
    separately, so that the paired operator who types a verb to the WRONG bot is told where to send it.)"""
    if _session_env("HERMES_SESSION_PLATFORM").strip().lower() != "telegram":
        return "not a telegram session"
    if _session_env("HERMES_SESSION_CHAT_TYPE").strip().lower() != "dm":
        return "not a direct message"
    operator = (os.environ.get("FORGE_OPERATOR_TELEGRAM_ID", "") or _scoped_env("FORGE_OPERATOR_TELEGRAM_ID")).strip()
    if not _USER_ID_RE.match(operator):
        return "FORGE_OPERATOR_TELEGRAM_ID is unset or malformed"
    user = _session_env("HERMES_SESSION_USER_ID").strip()
    chat = _session_env("HERMES_SESSION_CHAT_ID").strip()
    if user != operator or chat != operator:
        return "user or chat is not the operator's"
    return _allow_all_problem()


# ---------------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------------
def _parse(verb: str, raw_args: str) -> Tuple[Optional[List[str]], Optional[str]]:
    """The script's argv after its name, or a refusal. Shapes only; the script checks the board."""
    parts = (raw_args or "").strip().split(None, 2)
    if len(parts) < 2:
        return None, f"/{verb} needs {_ARGS_HINT[verb]}"
    board, gate = parts[0], parts[1]
    text = parts[2].strip() if len(parts) > 2 else ""
    if not _BOARD_RE.match(board) or "--" in board:
        return None, f"'{board[:40]}' is not a board name"
    if not _GATE_RE.match(gate):
        return None, f"'{gate[:40]}' is not a gate id (GATE-<milestone>)"
    if verb in _TEXT_REQUIRED and not text:
        return None, f"/{verb} needs {_ARGS_HINT[verb]}"
    if len(text) > _TEXT_MAX:
        return None, f"the text is {len(text)} characters; the limit is {_TEXT_MAX}"
    if _CONTROL_RE.search(text):
        return None, "the text has control characters"
    argv = ["--board", board, "--gate", gate]
    if text:
        argv += ["--text", text]
    argv.append("--apply")
    return argv, None


def _ledger_path(chat_id: str, message_id: str) -> str:
    return os.path.join(_state_root(), "gateway", "ledger", f"{chat_id}-{message_id}.json")


def _ledger_write(path: str, record: Dict[str, Any]) -> None:
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(record, fh)
    os.replace(tmp, path)


def _child_env() -> Dict[str, str]:
    env = {k: os.environ[k] for k in _ENV_KEEP if k in os.environ}
    env.update(_EXTRA_ENV)
    return env


def _run_script(script: str, argv: List[str]) -> Tuple[str, Optional[int], str, str]:
    """('done'|'timeout'|'error', rc, stdout, stderr). The child leads its own process group, so a
    timeout kills the whole group: a `hermes kanban complete` grandchild must not land after the reply."""
    proc = subprocess.Popen(["bash", script, *argv], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=_child_env(), start_new_session=True, close_fds=True)
    try:
        out, err = proc.communicate(timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass
        try:
            proc.communicate(timeout=5)
        except Exception:
            pass
        return "timeout", None, "", ""
    return "done", proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def _reply_for(status: str, rc: Optional[int], out: str, err: str) -> str:
    out, err = out.strip(), err.strip()
    if status == "timeout":
        return (f"outcome unknown: the script did not finish in {TIMEOUT_S} s and was stopped. "
                "Check the card before sending anything again.")
    if rc == 0:
        return out or "done."
    if rc == 1:
        return out if out.startswith("refused:") else f"refused: {out or 'no reason given'}"
    if rc == 2:
        if out.startswith("failed:"):
            return out
        reason = out or (err.splitlines()[-1] if err else "no reason given")
        return f"failed: {reason}"
    if rc == 3:
        return out or "unconfirmed: the write was made but could not be confirmed; check the card."
    return f"outcome unknown: the script ended abnormally (exit {rc}). Check the card before sending anything again."


def _handle_inner(verb: str, raw_args: str, state: Dict[str, bool]) -> str:
    script_name = VERB_SCRIPTS.get(verb)
    if script_name is None:
        return "refused: not a gate command."
    problem = _sender_problem()
    if problem is not None:
        logger.warning("forge-gateway: /%s refused: %s", verb, problem)
        return "refused: this chat is not paired for gate commands."
    if _session_profile() != GATE_PROFILE:
        logger.warning("forge-gateway: /%s refused: profile %r is not %s", verb, _session_profile(), GATE_PROFILE)
        return WRONG_BOT_REPLY
    chat_id = _session_env("HERMES_SESSION_CHAT_ID").strip()
    message_id = _session_env("HERMES_SESSION_MESSAGE_ID").strip()
    if not _CHAT_ID_RE.match(chat_id) or not _MESSAGE_ID_RE.match(message_id):
        return "refused: this message has no id, so it cannot be told from a replay."
    argv, why = _parse(verb, raw_args)
    if argv is None:
        return f"refused: {why}."
    script = os.path.join(_forge_repo(), "scripts", script_name)
    if not os.path.isfile(script):
        return f"refused: {script_name} is not installed at {os.path.dirname(script)}."

    path = _ledger_path(chat_id, message_id)
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        try:
            with open(path, encoding="utf-8") as fh:
                first = json.load(fh)
            if first.get("rc") is not None and isinstance(first.get("reply"), str):
                return first["reply"]
        except Exception:
            pass
        return ("refused: this message was already received and its outcome was not recorded. "
                "Check the card, then send the verb again as a new message.")
    except OSError as exc:
        logger.warning("forge-gateway: ledger unavailable: %s", exc)
        return "refused: the message ledger is unavailable, so nothing was run."
    record: Dict[str, Any] = {
        "schema": LEDGER_SCHEMA, "chat_id": chat_id, "message_id": message_id, "verb": verb,
        "args_sha256": hashlib.sha256("\x00".join(argv).encode("utf-8")).hexdigest(),
        "at": int(time.time()), "rc": None, "reply": None,
    }
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh)

    state["ran"] = True
    status, rc, out, err = _run_script(script, argv)
    reply = _reply_for(status, rc, out, err)[:_REPLY_CAP]
    record["rc"] = rc if status == "done" else -1
    record["reply"] = reply
    try:
        _ledger_write(path, record)
    except Exception as exc:
        logger.warning("forge-gateway: could not finish the ledger entry: %s", exc)
    return reply


def _handle(verb: str, raw_args: str) -> str:
    """Never raises: a handler that raises falls through to the agent as text (run_inbound.py)."""
    state = {"ran": False}
    try:
        return _handle_inner(verb, raw_args, state)
    except Exception as exc:  # noqa: BLE001 - this is the point
        logger.warning("forge-gateway: /%s failed: %s: %s", verb, type(exc).__name__, exc)
        if state["ran"]:
            return "outcome unknown: the handler failed after the script started. Check the card before sending anything again."
        return "refused: the handler failed before anything was run."


def _make_handler(verb: str):
    def handler(raw_args: str = "") -> str:
        return _handle(verb, raw_args)
    handler.__name__ = f"forge_gateway_{verb}"
    return handler


# ---------------------------------------------------------------------------
# The guard
# ---------------------------------------------------------------------------
_NON_MESSAGING = frozenset({"cli", "tui", "desktop", "local", "tool", "kanban", "api_server", "webhook",
                            "gateway", "codex", "msgraph_webhook"})
_READ_VERBS = frozenset({"list", "show", "runs", "log", "tail", "stats", "context"})
_BOARDS_READ = frozenset({"list", "ls"})
_KANBAN_READ_TOOLS = frozenset({"kanban_show", "kanban_list", "kanban_attachments"})
_TEXT_TOOLS = frozenset({"terminal", "execute_code", "process_manage"})
_FILE_TOOLS = frozenset({"write_file", "patch"})
# On a forge-gate turn the toolset is empty, so no tool call should exist at all; the guard is the second wall. The
# only calls that pass are board READS, which change nothing (an assertion in `gateway/` holds the list to that).
_GATE_READONLY = frozenset(_KANBAN_READ_TOOLS)
BLOCK_MESSAGE = ("forge-gateway: refused. A board write cannot be made from a chat turn. To act on a gate, "
                 "send /accept, /redirect or /park as its own message to the forge-gate bot; if the bot is "
                 "busy, send /stop first.")
RELATIVE_PATH_MESSAGE = ("forge-gateway: refused. That relative path could not be placed, and a write under forge's "
                         "state, scripts, plugins, config or boards is not made from a chat turn. Use an absolute path.")
PATCH_MESSAGE = ("forge-gateway: refused. That patch could not be read with Hermes' own patch parser, so the files it "
                 "names could not be checked.")
GATE_BLOCK_MESSAGE = ("forge-gate: refused. This bot has no tools. It explains /accept, /redirect and /park and "
                      "does nothing else; send a verb as its own message.")


def _is_gate_session() -> bool:
    """A turn of the forge-gate profile: every tool call but a board read is refused."""
    return _session_profile() == GATE_PROFILE


def _applies() -> bool:
    """A messaging session that is not a kanban worker."""
    if os.environ.get("HERMES_KANBAN_TASK"):
        return False
    platform = (_session_env("HERMES_SESSION_PLATFORM") or os.environ.get("HERMES_PLATFORM") or "").strip().lower()
    if platform:
        return platform not in _NON_MESSAGING
    # No platform bound: a plain CLI says nothing, but a gateway process (it has bound a session before)
    # treats an unbound turn as messaging, as Hermes does (default-deny).
    return _gateway_engaged()


def _strings(value: Any, out: List[str], depth: int = 0) -> None:
    if depth > 6:
        return
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for v in value.values():
            _strings(v, out, depth + 1)
    elif isinstance(value, (list, tuple)):
        for v in value:
            _strings(v, out, depth + 1)


def _text_is_a_board_write(text: str) -> bool:
    """True when the text names a board other than to read it. Quotes and backslashes are removed first, as
    a shell removes them: kan"ban" is kanban. Every token that holds `kanban` must be the word itself,
    followed (after options) by a read verb; `kanban.db`, `kanban_db`, `~/.hermes/kanban/...` are hits."""
    low = re.sub(r"[\\'\"]", "", text.lower())
    if "kanban" not in low:
        return False
    tokens = [t for t in re.split(r"[\s;|&(){}<>`$,=\[\]]+", low) if t]
    for i, tok in enumerate(tokens):
        if "kanban" not in tok:
            continue
        if tok != "kanban":
            return True
        j = i + 1
        while j < len(tokens) and tokens[j].startswith("-"):
            j += 2 if tokens[j] in ("--board", "-b") else 1
        verb = tokens[j] if j < len(tokens) else ""
        if verb == "boards":
            nxt = j + 1
            while nxt < len(tokens) and tokens[nxt].startswith("-"):
                nxt += 1
            if nxt < len(tokens) and tokens[nxt] in _BOARDS_READ:
                continue
            return True
        if verb not in _READ_VERBS:
            return True
    return False


def _protected_roots() -> List[str]:
    home = _home()
    hermes = os.environ.get("HERMES_HOME") or os.path.join(home, ".hermes")
    roots = [_state_root(), _forge_repo(),
             *(os.path.join(hermes, d) for d in ("scripts", "plugins", "profiles", "kanban", "hooks", "cron")),
             os.path.join(hermes, "config.yaml"), os.path.join(hermes, "kanban.db"),
             os.path.join(hermes, "kanban.db-wal"), os.path.join(hermes, "kanban.db-shm")]
    out: List[str] = []
    for r in roots:
        out.append(os.path.abspath(r))
        out.append(os.path.realpath(r))
    return out


def _resolve_relative(path: str, task_id: str) -> Optional[str]:
    """Where Hermes' own file tools would put a relative path: against the task's workspace root, which is not
    this process's cwd (`tools.file_tools_paths._resolve_path_for_task`). None when Hermes cannot say."""
    try:
        from tools.file_tools_paths import _resolve_path_for_task
        return str(_resolve_path_for_task(path, task_id or "default"))
    except Exception:
        return None


def _fold(path: str) -> str:
    """Case-fold for comparison (see _path_verdict)."""
    return path.casefold()


def _path_verdict(path: str, task_id: str = "") -> Optional[str]:
    """'protected', 'unplaced' (a relative path Hermes cannot place, refused), or None.

    Compared CASE-INSENSITIVELY, on every platform: APFS (the mini's) is case-insensitive, so `~/.FORGE/checkpoint` IS
    `~/.forge/checkpoint` there, and a comparison that is not folded is a hole on exactly one OS. Folding on all of
    them makes it testable on Linux CI too, at the price of refusing a path that differs from a protected one only in
    case on a case-sensitive disk."""
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        candidates = [os.path.abspath(expanded), os.path.realpath(expanded)]
    else:
        resolved = _resolve_relative(path, task_id)
        if resolved is None:
            return "unplaced"
        candidates = [os.path.abspath(resolved), os.path.realpath(resolved)]
    roots = [_fold(r) for r in _protected_roots()]
    for candidate in candidates:
        folded = _fold(candidate)
        for root in roots:
            if folded == root or folded.startswith(root.rstrip(os.sep) + os.sep):
                return "protected"
    return None


def _patch_paths(text: str) -> Optional[List[str]]:
    """Every file a V4A patch names, as HERMES's own parser reads it (tools/patch_parser.py: `***` markers with or
    without a space, and `*** Move File: a -> b`, which names two). None when the parser cannot be imported or the
    patch does not parse: a patch that cannot be read cannot be checked, so the caller refuses it."""
    try:
        from tools.patch_parser import parse_v4a_patch
        operations, error = parse_v4a_patch(text)
    except Exception:
        return None
    if error:
        return None
    paths: List[str] = []
    for op in operations:
        paths.append(op.file_path)
        if getattr(op, "new_path", None):
            paths.append(op.new_path)
    return paths


def _file_tool_verdict(args: Dict[str, Any], task_id: str = "") -> Optional[str]:
    paths: List[str] = []
    for key in ("path", "file_path", "filepath", "filename", "target"):
        v = args.get(key)
        if isinstance(v, str) and v:
            paths.append(v)
    verdicts: List[Optional[str]] = []
    patch = args.get("patch")
    if isinstance(patch, str) and patch.strip():
        named = _patch_paths(patch)
        if named is None:
            verdicts.append("unparsed")
        else:
            paths += named
    verdicts += [_path_verdict(p, task_id) for p in paths]
    for want in ("protected", "unparsed", "unplaced"):
        if want in verdicts:
            return want
    return None


def _decide(tool_name: str, args: Any, task_id: str = "") -> Optional[Dict[str, str]]:
    name = (tool_name or "").lower()
    args = args if isinstance(args, dict) else {}
    block = {"action": "block", "message": BLOCK_MESSAGE}
    if name.startswith("kanban_"):
        return None if name in _KANBAN_READ_TOOLS else block
    if name in _TEXT_TOOLS:
        strings: List[str] = []
        _strings(args, strings)
        return block if _text_is_a_board_write("\n".join(strings)) else None
    if name in _FILE_TOOLS:
        verdict = _file_tool_verdict(args, task_id)
        if verdict == "protected":
            return block
        if verdict == "unparsed":
            return {"action": "block", "message": PATCH_MESSAGE}
        if verdict == "unplaced":
            return {"action": "block", "message": RELATIVE_PATH_MESSAGE}
        return None
    if name == "cronjob_manage":
        # A cron job that runs a SCRIPT is a direct, non-agent way to run a command. (The owner's main agent keeps its
        # `cronjob` tool, owner ruling 2026-11-11: a prompt job passes here. The forge-gate profile has no tools.)
        return block if (args.get("script") or args.get("monitor_script")) else None
    return None


def _decide_gate(tool_name: str) -> Optional[Dict[str, str]]:
    """forge-gate: nothing but a board read. An unknown tool, a future tool and an MCP tool are all refused by default."""
    return None if (tool_name or "").lower() in _GATE_READONLY else {"action": "block", "message": GATE_BLOCK_MESSAGE}


def _could_write_a_board(tool_name: str) -> bool:
    name = (tool_name or "").lower()
    return name.startswith("kanban_") or name in _TEXT_TOOLS or name in _FILE_TOOLS or name == "cronjob_manage"


def _guard(tool_name: str = "", args: Any = None, task_id: str = "", **_: Any) -> Optional[Dict[str, str]]:
    """Never raises: a hook that raises blocks EVERY tool. On an internal error it blocks the tools that
    could write a board and passes the rest (and, on a forge-gate turn, blocks all of them)."""
    try:
        if _is_gate_session():
            return _decide_gate(tool_name)
        # The owner's main agent keeps its tools (decision 14). The tripwire on its turns is defence in depth, and the owner's
        # to switch off: FORGE_GATEWAY_MAIN_GUARD=off in ~/.hermes/.env, read from the gateway's environment. It is ON unless
        # the value is exactly off, 0, false or no (any other value, or none, leaves it on); it is checked AFTER the forge-gate
        # test above, so no value of it ever spares a forge-gate turn; and it is an operator switch, not a security boundary.
        if os.environ.get("FORGE_GATEWAY_MAIN_GUARD", "").strip().lower() in ("off", "0", "false", "no"):
            return None
        if not _applies():
            return None
        return _decide(tool_name, args, task_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("forge-gateway guard: internal error on %s: %s", tool_name, exc)
        if _could_write_a_board(tool_name):
            return {"action": "block", "message": BLOCK_MESSAGE}
        return None


# ---------------------------------------------------------------------------
def register(ctx) -> None:
    for verb in VERB_SCRIPTS:
        ctx.register_command(verb, _make_handler(verb), description=_DESCRIPTION[verb], args_hint=_ARGS_HINT[verb])
    ctx.register_hook("pre_tool_call", _guard)
