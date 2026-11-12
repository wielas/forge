"""Drive the forge-gateway plugin without Hermes (epic GW3, S8d). Used only by `make verify` (gateway/).

The plugin imports Hermes lazily and only through two seams, `_session_env` and `_gateway_engaged`, so
this file runs under a plain python3 and the handler/guard logic is exercised on a runner with no
Hermes at all. The session the gateway would bind (platform, chat, user, message) is given as JSON.

  gateway-drive.py handler --plugin DIR --session JSON --verb V --args TEXT [--repeat N] [--timeout S]
                           [--raise sender|session] [--child-env JSON] [--direct] [--scoped JSON]
      Calls the handler the plugin REGISTERS for V (the entry point the gateway calls) N times and
      prints {"replies": [...], "raised": null | "<exception>", "registered": [...]}. A verb the plugin
      did not register has no handler; the gateway would hand that text to the agent, and this prints
      {"no_handler": true}. --direct skips the registry and calls the plugin's own `_handle(verb, args)`,
      which is how the allowlist answers a verb that was never registered. --raise makes a seam raise, to prove the handler still returns a string.
  gateway-drive.py table --plugin DIR
      Prints the allowlist, the syntax hint of each verb, what the plugin registers, its hooks and the state root it resolves.
  gateway-drive.py guard --plugin DIR --session JSON --calls JSON [--engaged 0|1] [--env JSON] [--break applies|decide]
      --scoped JSON (both modes) is what the profile's secret scope holds, separate from the process environment.
      Calls the pre_tool_call hook for each {"tool": ..., "args": ...} and prints
      {"decisions": ["block" | "pass" | "raised: ..."]}.
"""

import argparse
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True


class FakeCtx:
    def __init__(self):
        self.commands = {}
        self.hooks = []

    def register_command(self, name, handler, description="", args_hint="", argument_mode=None):
        self.commands[name] = handler

    def register_hook(self, name, callback):
        self.hooks.append((name, callback))


def load(plugin_dir, session):
    spec = importlib.util.spec_from_file_location("forge_gateway_under_test", os.path.join(plugin_dir, "__init__.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod._session_env = lambda name: session.get(name, "")
    mod._scoped = {}
    mod._scoped_env = lambda name: mod._scoped.get(name, "")
    return mod


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["handler", "guard", "table"])
    ap.add_argument("--child-env", default="{}")
    ap.add_argument("--scoped", default="{}")
    ap.add_argument("--plugin", required=True)
    ap.add_argument("--session", default="{}")
    ap.add_argument("--verb")
    ap.add_argument("--args", default="")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--timeout", type=float)
    ap.add_argument("--direct", action="store_true")
    ap.add_argument("--raise", dest="raise_", choices=["sender", "session"])
    ap.add_argument("--calls", default="[]")
    ap.add_argument("--engaged", default="0")
    ap.add_argument("--env", default="{}")
    ap.add_argument("--break", dest="break_", choices=["applies", "decide"])
    a = ap.parse_args()

    session = json.loads(a.session)
    mod = load(a.plugin, session)
    mod._scoped.update(json.loads(a.scoped))
    ctx = FakeCtx()
    mod.register(ctx)

    if a.mode == "table":
        print(json.dumps({"table": mod.VERB_SCRIPTS, "hints": mod._ARGS_HINT, "registered": sorted(ctx.commands),
                          "hooks": [n for n, _ in ctx.hooks], "state_root": mod._state_root()}))
        return

    if a.mode == "handler":
        mod._EXTRA_ENV.update(json.loads(a.child_env))
        if a.timeout is not None:
            mod.TIMEOUT_S = a.timeout
        if a.raise_ == "sender":
            def boom():
                raise RuntimeError("injected failure in the sender check")
            mod._sender_problem = boom
        elif a.raise_ == "session":
            def boom2(name):
                raise ImportError("injected: gateway.session_context is not importable")
            mod._session_env = boom2
        handler = ctx.commands.get(a.verb)
        if a.direct:
            # The plugin's own entry point, whatever the verb: how the allowlist itself answers.
            handler = lambda raw, _v=a.verb: mod._handle(_v, raw)
        if handler is None:
            print(json.dumps({"no_handler": True, "registered": sorted(ctx.commands)}))
            return
        replies, raised = [], None
        for _ in range(a.repeat):
            try:
                replies.append(handler(a.args))
            except BaseException as exc:  # the point: a handler must not raise
                raised = f"{type(exc).__name__}: {exc}"
                break
        print(json.dumps({"replies": replies, "raised": raised, "registered": sorted(ctx.commands)}))
        return

    # guard
    mod._gateway_engaged = lambda: a.engaged == "1"
    os.environ.pop("FORGE_GATEWAY_MAIN_GUARD", None)   # the harness's own shell must not decide a case
    for k, v in json.loads(a.env).items():
        os.environ[k] = v
    if a.break_ == "applies":
        def boom3():
            raise RuntimeError("injected failure in _applies")
        mod._applies = boom3
    elif a.break_ == "decide":
        def boom4(*_a, **_k):
            raise RuntimeError("injected failure in _decide")
        mod._decide = boom4
    hooks = [cb for name, cb in ctx.hooks if name == "pre_tool_call"]
    if len(hooks) != 1:
        print(json.dumps({"error": f"expected exactly one pre_tool_call hook, found {len(hooks)}"}))
        return
    out = []
    for call in json.loads(a.calls):
        try:
            r = hooks[0](tool_name=call["tool"], args=call.get("args", {}))
            out.append("block" if isinstance(r, dict) and r.get("action") == "block" and r.get("message") else "pass")
        except BaseException as exc:
            out.append(f"raised: {type(exc).__name__}: {exc}")
    print(json.dumps({"decisions": out}))


main()
