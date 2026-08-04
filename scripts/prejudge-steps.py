#!/usr/bin/env python3
"""Every `Then` step must assert on a value (audit F14).

Scenario theater is the single most-cited defect in every chunk of the
forgeboard-report run, and it was cited by the *human* tier every time: the
implementer writes the scenarios, marks them green and self-reports coverage,
tier 1 approves 3/3, and only tier 2 ever reads the steps. That is one careful
reader guarding a 4,800-line test surface.

Two of the five representative defects the audit lists are decidable from the
syntax tree alone, and this walks it:

  no-assertion   a function decorated `@then(...)` whose body contains no
                 assertion at all. It can compute anything, return anything,
                 and pytest-bdd will mark the scenario green.
  tautology      an assertion whose two sides are the SAME EXPRESSION. This is
                 `test_render.py:198-200` verbatim — determinism defined as
                 `render(report) == render(report)` — and it passes whatever the
                 code does, because both sides move together.

What it deliberately does NOT claim. The other three defects the audit lists
(monkeypatching the unit under test, setting env vars that need a syscall to
take effect, weakening an assertion's subject) are semantic and are not
decidable here. This is a floor, not a ceiling: it proves a Then step makes a
claim, never that the claim is the right one. Read the reported recall as a
lower bound and keep tier 2 for the rest.

Usage:  prejudge-steps.py <dir-or-file>...     # JSON on stdout, exit 0 always
        The gate reads the JSON and decides; this program only reports.
"""

from __future__ import annotations

import ast
import json
import sys
from pathlib import Path

# `pytest.raises`/`pytest.fail`/`unittest` assertions are assertions. A step
# that uses them makes a checkable claim, which is the property under test —
# `assert` is not the only spelling and treating it as the only one would
# manufacture findings against perfectly good steps.
_ASSERTING_CALLS = {"fail", "raises", "approx"}
_ASSERT_METHOD_PREFIX = "assert"


def _is_then(func: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    for dec in func.decorator_list:
        target = dec.func if isinstance(dec, ast.Call) else dec
        name = target.attr if isinstance(target, ast.Attribute) else getattr(target, "id", "")
        if name == "then":
            return True
    return False


def _asserting_call(node: ast.Call) -> bool:
    fn = node.func
    if isinstance(fn, ast.Attribute):
        name = fn.attr
    elif isinstance(fn, ast.Name):
        name = fn.id
    else:
        return False
    # Leading underscores are stripped before the prefix test. Without this the
    # walker reported four FALSE POSITIVES on forgeboard-report PR #11 — four
    # Then steps delegating to a module-private `_assert_failures` helper that
    # asserts four times. False positives are how a gate gets switched off, and
    # this one was found by reading the flagged code instead of trusting the
    # count, which is the only way it could have been found.
    return name in _ASSERTING_CALLS or name.lstrip("_").startswith(_ASSERT_METHOD_PREFIX)


def _tautological(test: ast.expr) -> bool:
    """Both sides of a comparison are the same expression, so it cannot fail."""
    if not isinstance(test, ast.Compare) or len(test.comparators) != 1:
        return False
    if not isinstance(test.ops[0], (ast.Eq, ast.Is, ast.LtE, ast.GtE)):
        return False
    return ast.dump(test.left) == ast.dump(test.comparators[0])


def inspect(path: Path) -> tuple[int, list[dict[str, object]]]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (SyntaxError, UnicodeDecodeError) as exc:
        return 0, [{"file": str(path), "line": 0, "func": "<module>",
                    "kind": "unparseable", "detail": str(exc)}]

    steps = 0
    offenders: list[dict[str, object]] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        is_then = _is_then(node)
        # The tautology check runs over plain `test_*` functions too, and that
        # is a deliberate widening of F35's "AST walk of tests/steps/*.py". The
        # exact defect the audit cites for it — `test_render.py:198-200`,
        # determinism as `render(report) == render(report)` — is a plain pytest
        # test, not a Then step. Scoped to steps/ the walk would report zero
        # while the cited defect sat in the tree. `no-assertion` stays scoped to
        # Then steps, where "the step made no claim" is the whole contract; a
        # unit test with no assert is a different argument this does not make.
        if not is_then and not node.name.startswith("test_"):
            continue
        if is_then:
            steps += 1

        asserts = [n for n in ast.walk(node) if isinstance(n, ast.Assert)]
        calls = [n for n in ast.walk(node) if isinstance(n, ast.Call) and _asserting_call(n)]
        withs = [
            n for n in ast.walk(node)
            if isinstance(n, (ast.With, ast.AsyncWith))
            and any(isinstance(i.context_expr, ast.Call) and _asserting_call(i.context_expr)
                    for i in n.items)
        ]
        if is_then and not asserts and not calls and not withs:
            offenders.append({"file": str(path), "line": node.lineno, "func": node.name,
                              "kind": "no-assertion",
                              "detail": "no assert, no pytest.raises/fail, no assert* call"})
            continue

        for a in asserts:
            if _tautological(a.test):
                offenders.append({"file": str(path), "line": a.lineno, "func": node.name,
                                  "kind": "tautology",
                                  "detail": "both sides of the comparison are the same expression"})
    return steps, offenders


def main(argv: list[str]) -> int:
    targets: list[Path] = []
    for arg in argv:
        p = Path(arg)
        if p.is_dir():
            targets.extend(sorted(p.rglob("*.py")))
        elif p.is_file():
            targets.append(p)

    steps = 0
    offenders: list[dict[str, object]] = []
    for path in targets:
        s, o = inspect(path)
        steps += s
        offenders.extend(o)

    json.dump({"files": len(targets), "then_steps": steps,
               "offenders": offenders}, sys.stdout, indent=None)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
