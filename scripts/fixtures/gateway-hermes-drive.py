"""Drive the forge-gateway plugin through the REAL Hermes (epic GW3, S8d). Used only by `make verify`.

Run with the Hermes venv's python3, `-I`, and HERMES_HOME pointing at an ISOLATED directory (the case
builds it: the plugin symlinked into plugins/ and enabled in config.yaml). Nothing here touches ~/.hermes.

  gateway-hermes-drive.py registry --names a,b,c
      Real plugin discovery from HERMES_HOME. Prints {"commands": {name: bool}, "loaded": [...], "hooks": n}:
      whether the gateway's own lookup, `get_plugin_command_handler`, finds a handler for each name (it
      lowercases nothing and the gateway first turns '_' into '-', so the case asks for both spellings).
  gateway-hermes-drive.py calls --session JSON --calls JSON
      The session JSON may carry "profile" (HERMES_SESSION_PROFILE: the profile that owns the receiving bot).
      Binds the session the way the gateway binds it for a turn (gateway.session_context.set_session_vars,
      a ContextVar, NOT os.environ) and makes each {"tool", "args"} call through the real
      model_tools.handle_function_call, which fires pre_tool_call before it looks the tool up. Prints
      {"results": [<the tool's JSON result string>, ...], "env_session_vars": [...]}; the last must be empty,
      or the case would be proving the os.environ fallback and not the context variable.
"""

import argparse
import json
import os
import sys

sys.dont_write_bytecode = True
AGENT = os.environ.get("HERMES_AGENT_DIR") or os.path.expanduser("~/.hermes/hermes-agent")
sys.path.insert(0, AGENT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["registry", "calls"])
    ap.add_argument("--names", default="")
    ap.add_argument("--session", default="{}")
    ap.add_argument("--calls", default="[]")
    a = ap.parse_args()

    home = os.environ.get("HERMES_HOME", "")
    if not home or os.path.realpath(home) == os.path.realpath(os.path.expanduser("~/.hermes")):
        print(json.dumps({"error": "refusing to run against ~/.hermes or an unset HERMES_HOME"}))
        sys.exit(2)

    if a.mode == "registry":
        from hermes_cli import plugins
        plugins.discover_plugins()
        mgr = plugins.get_plugin_manager()
        names = [n for n in a.names.split(",") if n]
        print(json.dumps({
            "commands": {n: plugins.get_plugin_command_handler(n) is not None for n in names},
            "loaded": sorted(getattr(mgr, "_plugin_commands", {}).keys()),
            "hooks": len(getattr(mgr, "_hooks", {}).get("pre_tool_call", [])),
        }))
        return

    from gateway.session_context import set_session_vars
    import model_tools
    s = json.loads(a.session)
    set_session_vars(platform=s.get("platform", ""), chat_id=s.get("chat_id", ""), chat_type=s.get("chat_type", ""),
                     user_id=s.get("user_id", ""), message_id=s.get("message_id", ""), profile=s.get("profile", ""))
    results = []
    for call in json.loads(a.calls):
        results.append(model_tools.handle_function_call(call["tool"], call.get("args", {}), task_id="gw-t", session_id="gw-s"))
    print(json.dumps({"results": results,
                      "env_session_vars": sorted(k for k in os.environ if k.startswith("HERMES_SESSION"))}))


main()
