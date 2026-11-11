"""What can each Telegram agent call? Asked of Hermes' OWN resolver, not of the YAML (epic GW3, S8d).

WHY IT EXISTS. The paired gateway is a DEDICATED Telegram bot bound to the profile `forge-gate` (owner ruling, 2026-11-11),
and what makes a gate verb that reaches an agent as text unable to become a board write is that THAT agent has no tools at
all. The owner's main Telegram agent keeps its tools; it is not judged here, only reported. A tripwire is a text match, and
`sqlite3`, a built-up `python -c` string, a backslash-newline split word or a sub-process get past one, so the claim rests on
the toolset, and a grep of config.yaml is not an answer: `platform_toolsets.telegram: [hermes-telegram]` holds a shell
without naming one, a profile with no entry at all resolves that default bundle, `agent.disabled_toolsets` removes tools by
name, and `_recover_platform_native_toolsets` adds some back. So this asks the code the gateway asks:
`hermes_cli.tools_config._get_platform_tools(config, platform)` for the enabled toolsets, and `toolsets.resolve_toolset` for
the tools each one holds.

WHAT IT PRINTS (one JSON object, on stdout):
  platform         the platform asked about
  root             {explicit, toolsets, tools, write_tools, shell_tools} of the root profile: the owner's main agent.
                   Informational.
  plugin_enabled   whether the ROOT config's `plugins.enabled` names forge-gateway (there it only refuses a verb)
  profiles         for each profile under <home>/profiles with a config.yaml:
                     explicit       its platform_toolsets names the platform (otherwise Hermes resolves the default bundle)
                     toolsets, tools, write_tools   what its resolution holds; write_tools is every tool that is not on the
                                    read-only list below, so an unknown or future tool counts as write-capable
                     plugin_enabled forge-gateway is in its `plugins.enabled`
                     plugin_link    its plugins/forge-gateway directory holds plugin.yaml and __init__.py
                     mcp_servers    how many MCP servers its config lists (each is a source of tools the toolset does not name)
                     unauthorized_dm_behavior   its top-level value (`ignore` means a stranger gets no pairing code)
                     own_token      its .env holds a non-empty TELEGRAM_BOT_TOKEN
                     token_shared_with_root   that token equals the root's (Hermes refuses the second adapter)
                     allowed_users  "none", "set" or "star" (TELEGRAM_ALLOWED_USERS in its .env)
                   No value from a .env file is printed; only these facts about it.
  forge_gate       profiles["forge-gate"], or null when that profile does not exist
  computer_use     {"enabled": bool, "available": bool} for the ROOT: the desktop-control tool drives any app
EXIT CODES: 0 it answered (whatever the answer is), 2 it could not: a Hermes module or function this code uses has
moved. "Could not ask" is never "nothing there" (preflight FAILs on 2; the case skips only where Hermes is absent).

Run it with the Hermes venv's python3, `-I`, with HERMES_HOME set to the home whose config.yaml is asked about.
Usage:  <python3> -I scripts/gateway-toolset-probe.py [--platform telegram]
It reads config and writes nothing: bytecode writing is off before Hermes is imported.
"""

import argparse
import json
import os
import re
import sys

sys.dont_write_bytecode = True
GATE_PROFILE = "forge-gate"
# Tools that change nothing. Everything else a toolset holds is treated as write-capable, so a tool nobody has heard of
# yet cannot slip into forge-gate unseen.
READ_ONLY_TOOLS = frozenset({
    "web_search", "web_extract", "read_file", "search_files", "vision_analyze", "skills_list", "skill_view",
    "session_search", "clarify", "kanban_show", "kanban_list", "kanban_attachments",
    "ha_list_entities", "ha_get_state", "ha_list_services",
})
# The tools that can run a command, or make something else run one: a chat-made cron job can carry a prompt whose agent has
# the shell toolset (tools/cronjob_tools.py `_action_create` does not limit its toolsets) or a script.
SHELL_TOOLS = ("terminal", "process_manage", "execute_code", "cronjob_manage")


def cannot_run(why):
    print(json.dumps({"error": why}))
    sys.exit(2)


def env_value(path, key):
    """The value of KEY in a dotenv file, or None. Never printed by this program."""
    try:
        with open(path, encoding="utf-8") as fh:
            found = None
            for line in fh:
                m = re.match(r"^\s*(?:export\s+)?" + re.escape(key) + r"\s*=\s*(.*?)\s*$", line.rstrip("\n"))
                if m:
                    found = m.group(1).strip("'\"")
            return found
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", default="telegram")
    a = ap.parse_args()
    agent = os.environ.get("HERMES_AGENT_DIR") or os.path.expanduser("~/.hermes/hermes-agent")
    if not os.path.isdir(agent):
        cannot_run(f"no Hermes checkout at {agent}")
    sys.path.insert(0, agent)
    try:
        import yaml
        from hermes_cli.config import load_config_readonly
        from hermes_cli.tools_config import _get_platform_tools
        from toolsets import resolve_toolset
    except Exception as exc:  # noqa: BLE001
        cannot_run(f"a Hermes module this probe uses has moved: {type(exc).__name__}: {exc}")

    def resolve(cfg):
        enabled = sorted(_get_platform_tools(cfg, a.platform))
        tools = set()
        for ts in enabled:
            try:
                tools |= set(resolve_toolset(ts))
            except Exception:
                pass          # an MCP or plugin toolset the static table does not know holds no built-in tool
        explicit = isinstance((cfg.get("platform_toolsets") or {}).get(a.platform), (list, str))
        return enabled, sorted(tools), explicit

    home = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
    try:
        cfg = load_config_readonly()
        r_toolsets, r_tools, r_explicit = resolve(cfg)
    except Exception as exc:  # noqa: BLE001
        cannot_run(f"Hermes would not resolve the {a.platform} toolset: {type(exc).__name__}: {exc}")

    def plugin_listed(c):
        plugins = c.get("plugins") if isinstance(c, dict) else None
        listed = plugins.get("enabled") if isinstance(plugins, dict) else None
        return isinstance(listed, list) and "forge-gateway" in listed

    root_token = env_value(os.path.join(home, ".env"), "TELEGRAM_BOT_TOKEN") or ""
    profiles = {}
    try:
        pdir = os.path.join(home, "profiles")
        for name in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
            cfile = os.path.join(pdir, name, "config.yaml")
            if not os.path.isfile(cfile):
                continue
            with open(cfile, encoding="utf-8") as fh:
                pcfg = yaml.safe_load(fh) or {}
            if not isinstance(pcfg, dict):
                continue
            toolsets, tools, explicit = resolve(pcfg)
            penv = os.path.join(pdir, name, ".env")
            token = env_value(penv, "TELEGRAM_BOT_TOKEN") or ""
            allowed = (env_value(penv, "TELEGRAM_ALLOWED_USERS") or "").strip()
            link = os.path.join(pdir, name, "plugins", "forge-gateway")
            mcp = pcfg.get("mcp_servers")
            profiles[name] = {
                "explicit": explicit,
                "toolsets": toolsets,
                "tools": tools,
                "write_tools": sorted(t for t in tools if t not in READ_ONLY_TOOLS),
                "plugin_enabled": plugin_listed(pcfg),
                "plugin_link": os.path.isfile(os.path.join(link, "plugin.yaml")) and os.path.isfile(os.path.join(link, "__init__.py")),
                "mcp_servers": len(mcp) if isinstance(mcp, (dict, list)) else 0,
                "unauthorized_dm_behavior": pcfg.get("unauthorized_dm_behavior"),
                "own_token": bool(token),
                "token_shared_with_root": bool(token) and token == root_token,
                "allowed_users": "none" if not allowed else ("star" if "*" in re.split(r"[\s,]+", allowed) else "set"),
            }
    except Exception as exc:  # noqa: BLE001
        cannot_run(f"Hermes would not resolve a profile's {a.platform} toolset: {type(exc).__name__}: {exc}")

    available = False
    try:
        from tools.computer_use.tool import check_computer_use_requirements
        available = bool(check_computer_use_requirements())
    except Exception:
        available = False
    print(json.dumps({
        "platform": a.platform,
        "root": {"explicit": r_explicit, "toolsets": r_toolsets, "tools": r_tools,
                 "write_tools": sorted(t for t in r_tools if t not in READ_ONLY_TOOLS),
                 "shell_tools": sorted(t for t in r_tools if t in SHELL_TOOLS)},
        "plugin_enabled": plugin_listed(cfg),
        "profiles": profiles,
        "forge_gate": profiles.get(GATE_PROFILE),
        "computer_use": {"enabled": "computer_use" in r_toolsets or "computer_use" in r_tools, "available": available},
    }))


main()
