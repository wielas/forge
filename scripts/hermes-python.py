"""Print the installed Hermes interpreter for Forge's read-only integration probes.

PM releases select a dependency generation outside the checkout. Earlier releases
use venv/. Consult Hermes' selection API rather than guessing a generation path.
This does not install dependencies or change the selected environment.
"""

import os
from pathlib import Path
import sys


def main():
    root = Path(os.environ.get("HERMES_AGENT_DIR", Path.home() / ".hermes/hermes-agent")).resolve()
    sys.dont_write_bytecode = True
    try:
        if (root / "pm/environments.py").is_file():
            sys.path.insert(0, str(root))
            from pm.environments import selected_venv, venv_python

            python = venv_python(selected_venv(root))
        else:
            python = root / "venv/bin/python3"
        if not python.is_file() or not os.access(python, os.X_OK):
            raise RuntimeError(f"Hermes interpreter is missing: {python}")
    except Exception as exc:
        print(f"cannot resolve Hermes Python: {exc}", file=sys.stderr)
        return 2
    print(python)
    return 0


if __name__ == "__main__":
    sys.exit(main())
