"""Which tools can a platform's agent call? Asked of Hermes' OWN resolver, not of the YAML (epic GW3, S8d).

WHY IT EXISTS. What makes a busy-path verb unable to become a board write is that the Telegram agent has no shell
and no cron: owner decision, 2026-11-09, on top of the forge-gateway plugin's tripwire guard (and the review of S8d
added `cronjob`: a chat-made cron job can run a prompt with the shell toolset). A tripwire is a text match, and
`sqlite3`, a built-up `python -c` string, a backslash-newline split word or a sub-process get past one. A grep of config.yaml for `terminal` is
not an answer either: `platform_toolsets.telegram: [hermes-telegram]` holds `terminal` without naming it,
`agent.disabled_toolsets` removes tools by name, and `_recover_platform_native_toolsets` adds some back. So this
asks the code the gateway asks: `hermes_cli.tools_config._get_platform_tools(config, platform)` for the enabled
toolsets, and `toolsets.resolve_toolset` for the tools each one holds.

WHAT IT PRINTS (one JSON object, on stdout):
  platform         the platform asked about
  toolsets         the enabled toolsets
  tools            every tool those toolsets hold
  shell_tools      the subset that can run a command, or make one run: terminal, process_manage, execute_code,
                   cronjob_manage
  profiles         for each profile under <home>/profiles that has its own config.yaml: {"explicit": whether its
                   platform_toolsets names the platform, "shell_tools": what its resolution holds}. A profile
                   that serves Telegram has its own toolset, so the root's says nothing about it. One that names
                   no telegram toolset resolves the default bundle (a shell), but only an EXPLICIT entry is a
                   deliberate Telegram toolset: callers judge those.
  computer_use     {"enabled": bool, "available": bool}: the desktop-control tool is the one route to a shell
                   that cannot be closed here, because it drives any app. It is dormant while cua-driver is absent.
  plugin_enabled   whether `plugins.enabled` names forge-gateway
EXIT CODES: 0 it answered (whatever the answer is), 2 it could not: a Hermes module or function this code uses has
moved. "Could not ask" is never "nothing there" (preflight FAILs on 2; the case skips only where Hermes is absent).

Run it with the Hermes venv's python3, `-I`, with HERMES_HOME set to the home whose config.yaml is asked about.
Usage:  <python3> -I scripts/gateway-toolset-probe.py [--platform telegram]
It reads config and writes nothing: bytecode writing is off before Hermes is imported.
"""

import argparse
import json
import os
import sys

sys.dont_write_bytecode = True
# The tools that run a command, or can make something else run one: a cron job a chat turn creates can carry a prompt
# whose agent has the shell toolset (tools/cronjob_tools.py `_action_create` does not limit its toolsets) or a script.
SHELL_TOOLS = ("terminal", "process_manage", "execute_code", "cronjob_manage")


def cannot_run(why):
    print(json.dumps({"error": why}))
    sys.exit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", default="telegram")
    a = ap.parse_args()
    agent = os.environ.get("HERMES_AGENT_DIR") or os.path.expanduser("~/.hermes/hermes-agent")
    if not os.path.isdir(agent):
        cannot_run(f"no Hermes checkout at {agent}")
    sys.path.insert(0, agent)
    try:
        from hermes_cli.config import load_config_readonly
        from hermes_cli.tools_config import _get_platform_tools
        from toolsets import resolve_toolset
    except Exception as exc:  # noqa: BLE001
        cannot_run(f"a Hermes module this probe uses has moved: {type(exc).__name__}: {exc}")
    try:
        cfg = load_config_readonly()
        enabled = sorted(_get_platform_tools(cfg, a.platform))
        tools = set()
        for ts in enabled:
            try:
                tools |= set(resolve_toolset(ts))
            except Exception:
                pass          # an MCP or plugin toolset the static table does not know holds no built-in tool
    except Exception as exc:  # noqa: BLE001
        cannot_run(f"Hermes would not resolve the {a.platform} toolset: {type(exc).__name__}: {exc}")
    available = False
    try:
        from tools.computer_use.tool import check_computer_use_requirements
        available = bool(check_computer_use_requirements())
    except Exception:
        available = False
    profiles = {}
    try:
        import yaml
        home = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
        pdir = os.path.join(home, "profiles")
        for name in sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []:
            cfile = os.path.join(pdir, name, "config.yaml")
            if not os.path.isfile(cfile):
                continue
            with open(cfile, encoding="utf-8") as fh:
                pcfg = yaml.safe_load(fh) or {}
            if not isinstance(pcfg, dict):
                continue
            ptools = set()
            for ts in _get_platform_tools(pcfg, a.platform):
                try:
                    ptools |= set(resolve_toolset(ts))
                except Exception:
                    pass
            explicit = isinstance((pcfg.get("platform_toolsets") or {}).get(a.platform), (list, str))
            profiles[name] = {"explicit": explicit, "shell_tools": sorted(t for t in ptools if t in SHELL_TOOLS)}
    except Exception as exc:  # noqa: BLE001
        cannot_run(f"Hermes would not resolve a profile's {a.platform} toolset: {type(exc).__name__}: {exc}")
    plugins = cfg.get("plugins") if isinstance(cfg, dict) else None
    listed = (plugins or {}).get("enabled") if isinstance(plugins, dict) else None
    print(json.dumps({
        "platform": a.platform,
        "toolsets": enabled,
        "tools": sorted(tools),
        "shell_tools": sorted(t for t in tools if t in SHELL_TOOLS),
        "profiles": profiles,
        "computer_use": {"enabled": "computer_use" in enabled or "computer_use" in tools, "available": available},
        "plugin_enabled": isinstance(listed, list) and "forge-gateway" in listed,
    }))


main()
