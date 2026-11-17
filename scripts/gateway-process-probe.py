"""Read the verified gateway's PATH without matching wrapper/test command lines."""

import os
from pathlib import Path
import sys


def main():
    sys.dont_write_bytecode = True
    root = Path(os.environ.get("HERMES_AGENT_DIR", Path.home() / ".hermes/hermes-agent")).resolve()
    sys.path.insert(0, str(root))
    from gateway.status import live_gateway_pid_for_home
    import psutil

    home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
    pid = live_gateway_pid_for_home(home)
    if pid is None:
        return
    env = psutil.Process(pid).environ()
    print(pid)
    print(env.get("PATH", ""))
    for key in ("HOME", "HERMES_HOME", "TERMINAL_CWD", "MESSAGING_CWD"):
        if key in env:
            print(f"{key}={env[key]}")


if __name__ == "__main__":
    main()
