"""Run installed Hermes code with its selected dependencies in an isolated test home.

The production PM launcher starts a store Python and prepares a new dependency
generation for each data root. Conformance fixtures instead borrow the selected
venv interpreter, which already has the dependencies, and disable lazy installs.
No live launcher, configuration, or PM selection is rewritten by these fixtures.
"""

import os
import sys

sys.path.insert(0, sys.argv.pop(1))
os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"

from hermes_cli.main import main

main()
