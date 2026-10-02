#!/usr/bin/env python3
"""The verifier's mutation probe (FL5): does any test OBSERVE each changed line?

WHY THIS EXISTS. Neither review tier caught JobApp C21's two blockers by
reading. A mutation did: the tier-2 judge deleted every config read the chunk
added, and the suite stayed green. C17's disabled-path message could be
rewritten freely because its Then step checked one word, and the July ladder's
PR #6 was CI-green with a Then step that asserted nothing. Each is a line of
implementation that no test can see, and each is decidable by EXECUTION: change
the line, run the tests, and see whether anything fails.

WHAT IT ASKS, PER LINE. For every implementation line the PR added or changed,
it applies a small fixed set of mutations and runs the project's tests against
each. A line on which EVERY mutant survived is UNOBSERVED: no test detects any
change to it. That — and only that — is a bounce reason, and it is reported as
one the implementer can act on: the file, the line, the mutations, and that no
test failed. A line with some mutants killed and some surviving IS observed;
its survivors are listed as notes and never bounce. The rule is per line, not
per mutant, because a single surviving mutant is often equivalent (the change
cannot alter behaviour), whereas a line on which no mutation of any kind is
noticed is a line no test reaches or no assertion pins.

WHAT IS IN SCOPE. Lines the PR adds or changes in `*.py` files that are not
tests (no `tests`/`test` directory component; not `test_*.py`, `*_test.py`,
`conftest.py`), read from `git diff <base> HEAD` in the tree Stage 1b merged.
Never mutated: comments, docstrings, blank lines, imports, annotations, and
logging calls — log text is not contract behaviour.

THE OPERATORS, in the order a line tries them (cheapest to equivalence first):
statement deletion (`raise` or a call statement -> `pass`), `return x` ->
`return None`, comparison negation (`==`/`!=`, `<`/`>=`, `>`/`<=`, `is`/`is
not`, `in`/`not in`), `and`/`or`, `not x` -> `x`, negating a bare condition,
`True`/`False`, a number n -> n+1, a string -> `""` (an empty one -> `"XX"`),
and an f-string -> `""`. Each mutant is a byte-exact edit of the original
source, re-parsed before it is used; one that does not parse is discarded.

THE BUDGET. Lines are probed BREADTH-FIRST: every line's first mutant runs
before any line's second, and a line stops at its first kill. So a tight budget
still gives every line one chance to be observed, and only lines that keep
surviving cost more runs. A line whose mutants were not all run when the budget
ended is "not fully probed", reported, and never a bounce reason. If no line at
all could be probed, the probe is unrunnable — a probe that did not run has not
passed.

WHAT COUNTS AS KILLED. Any non-zero exit of the test command, or a timeout
(the change was observable). That is only sound because the UNMUTATED tree is
run first with the same command and must exit 0; a red baseline is unrunnable,
because then a failure would say nothing about the mutant.

TWO TRAPS IT EXISTS TO AVOID:
  * The template's `addopts` carries `--cov-fail-under`. A mutant run that
    trips the coverage floor fails for a reason that has nothing to do with the
    mutant, which reads as a KILL and hides the survivor. The default test
    command clears `addopts` (`-o addopts=`). Measured: with the floor kept,
    `verifier/mutation-probe-mutation-is-caught` loses an unobserved line.
  * A stale bytecode cache — guarded by construction, never reproduced (it
    needs a same-size mutant written within the same second as its cache). Python reuses `__pycache__/*.pyc` when the source's
    recorded mtime and size match, and `==` -> `!=` keeps the size. A mutant
    written within the same second as the source would then run the ORIGINAL
    code and survive. Every run sets PYTHONDONTWRITEBYTECODE and the mutated
    file's cached bytecode is removed before and after it.

THE TREE IS LEFT AS FOUND. Every mutated file is restored from the bytes read
before the first mutant, in a `finally`, and on SIGTERM/SIGINT; at the end the
tracked tree is compared with its state at the start, and a difference makes
the result unrunnable rather than silently leaving a mutant behind.

Usage:
  mutation-probe.py --tree <dir> --base-sha <sha> [--budget <seconds>]
                    [--test-cmd <shell command>] [--max-per-line <n>]

Output: one `forge.mutation.v1` JSON object on stdout.
Exit:   0 pass · 1 survived (unobserved lines) · 2 usage · 3 unrunnable.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

SCHEMA = "forge.mutation.v1"
LOG_METHODS = {"debug", "info", "warning", "warn", "error", "exception", "critical", "log"}
NEGATED_CMP = {
    ast.Eq: "!=", ast.NotEq: "==", ast.Lt: ">=", ast.GtE: "<", ast.Gt: "<=",
    ast.LtE: ">", ast.Is: "is not", ast.IsNot: "is", ast.In: "not in", ast.NotIn: "in",
}
CMP_TEXT = {ast.Eq: "==", ast.NotEq: "!=", ast.Lt: "<", ast.GtE: ">=", ast.Gt: ">",
            ast.LtE: "<=", ast.Is: "is", ast.IsNot: "is not", ast.In: "in", ast.NotIn: "not in"}
# The order a line tries its mutants in. Statement-level mutations come first:
# they are the least likely to be equivalent, so a line that is observed at all
# is usually cleared by its first run.
PRIORITY = ["delete-statement", "return-none", "negate-comparison", "swap-boolean-operator",
            "remove-not", "negate-condition", "flip-boolean", "number-plus-one",
            "empty-string", "empty-fstring"]


@dataclass
class Mutant:
    file: str
    line: int
    op: str
    start: int          # byte offsets into the file's source
    end: int
    replacement: bytes
    original: bytes
    outcome: str = "not-run"

    @property
    def mutation(self) -> str:
        before = _short(self.original.decode("utf-8", "replace"))
        after = _short(self.replacement.decode("utf-8", "replace"))
        return f"{before} -> {after}"


@dataclass
class Line:
    file: str
    line: int
    source: str
    mutants: list[Mutant] = field(default_factory=list)


def _short(text: str, limit: int = 60) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def emit(result: str, evidence: str, code: int, **extra) -> None:
    out = {"schema": SCHEMA, "result": result, "evidence": evidence}
    out.update(extra)
    print(json.dumps(out, indent=None, sort_keys=False))
    sys.exit(code)


def git(tree: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(tree), *args], check=True,
                          capture_output=True, text=True).stdout


# ---------------------------------------------------------------------------
# Which lines changed.
# ---------------------------------------------------------------------------
def is_test_path(path: str) -> bool:
    parts = Path(path).parts
    name = parts[-1]
    return (any(p in ("tests", "test") for p in parts[:-1])
            or name.startswith("test_") or name.endswith("_test.py") or name == "conftest.py")


def changed_lines(tree: Path, base: str) -> dict[str, set[int]]:
    """Lines added or changed in HEAD relative to base, in HEAD's coordinates."""
    diff = git(tree, "diff", "--no-color", "--no-ext-diff", "--unified=0", "-M",
               base, "HEAD", "--", "*.py")
    out: dict[str, set[int]] = {}
    current = None
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:]
            current = None if target == "/dev/null" else target[2:] if target.startswith("b/") else target
            if current is not None and (not current.endswith(".py") or is_test_path(current)):
                current = None
        elif raw.startswith("@@") and current is not None:
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", raw)
            if m:
                start, count = int(m.group(1)), int(m.group(2) or "1")
                out.setdefault(current, set()).update(range(start, start + count))
    return {f: lines for f, lines in out.items() if lines}


# ---------------------------------------------------------------------------
# Mutants. Every one is a byte-exact edit of the original source.
# ---------------------------------------------------------------------------
class Offsets:
    """ast positions are (1-based line, UTF-8 byte column); map them to offsets."""

    def __init__(self, data: bytes):
        self.starts = [0]
        for i, b in enumerate(data):
            if b == 0x0A:
                self.starts.append(i + 1)

    def __call__(self, line: int, col: int) -> int:
        return self.starts[line - 1] + col


def _is_logging_call(call: ast.Call) -> bool:
    fn = call.func
    if not isinstance(fn, ast.Attribute) or fn.attr not in LOG_METHODS:
        return False
    target = fn.value
    while isinstance(target, ast.Attribute):
        if "log" in target.attr.lower():
            return True
        target = target.value
    return isinstance(target, ast.Name) and "log" in target.id.lower()


def _skipped_spans(module: ast.Module) -> list[tuple[int, int, int, int]]:
    """Docstrings, imports and annotations: never mutated."""
    spans = []

    def span(n: ast.AST) -> None:
        spans.append((n.lineno, n.col_offset, n.end_lineno, n.end_col_offset))

    for node in ast.walk(module):
        body = getattr(node, "body", None)
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) \
                and body and isinstance(body[0], ast.Expr) \
                and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            span(body[0])
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            span(node)
        if isinstance(node, ast.arg) and node.annotation is not None:
            span(node.annotation)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.returns is not None:
            span(node.returns)
        if isinstance(node, ast.AnnAssign):
            span(node.annotation)
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call) \
                and _is_logging_call(node.value):
            span(node)
    return spans


def _inside(n: ast.AST, spans) -> bool:
    for (l1, c1, l2, c2) in spans:
        if (n.lineno, n.col_offset) >= (l1, c1) and (n.end_lineno, n.end_col_offset) <= (l2, c2):
            return True
    return False


def generate(path: str, data: bytes, wanted: set[int]) -> dict[int, list[Mutant]]:
    try:
        module = ast.parse(data)
    except SyntaxError:
        return {}
    off = Offsets(data)
    skip = _skipped_spans(module)
    found: list[Mutant] = []

    def add(op, line, start, end, replacement: str | bytes):
        if line not in wanted:
            return
        rep = replacement.encode() if isinstance(replacement, str) else replacement
        found.append(Mutant(path, line, op, start, end, rep, data[start:end]))

    def node_span(n):
        return off(n.lineno, n.col_offset), off(n.end_lineno, n.end_col_offset)

    fstring_parts: set[int] = set()
    for node in ast.walk(module):
        if isinstance(node, ast.JoinedStr):
            for v in ast.walk(node):
                if v is not node:
                    fstring_parts.add(id(v))

    for node in ast.walk(module):
        if not hasattr(node, "lineno") or _inside(node, skip) or id(node) in fstring_parts:
            continue
        if isinstance(node, (ast.Raise,)) or (
                isinstance(node, ast.Expr) and isinstance(node.value, (ast.Call, ast.Await))):
            add("delete-statement", node.lineno, *node_span(node), "pass")
        elif isinstance(node, ast.Return) and node.value is not None \
                and not (isinstance(node.value, ast.Constant) and node.value.value is None):
            s, e = node_span(node.value)
            add("return-none", node.lineno, s, e, "None")
        elif isinstance(node, ast.Compare):
            left = node.left
            for op, right in zip(node.ops, node.comparators, strict=True):
                s = off(left.end_lineno, left.end_col_offset)
                e = off(right.lineno, right.col_offset)
                gap = data[s:e]
                text = CMP_TEXT[type(op)].encode()
                # The operator sits in the gap between the operands, possibly
                # wrapped in parentheses or comments; replace its first token.
                pattern = re.escape(text).replace(b" ", rb"\s+")
                m = re.search(rb"(?<![=!<>\w])" + pattern + rb"(?![=\w])", gap)
                if m:
                    add("negate-comparison", left.end_lineno, s + m.start(), s + m.end(),
                        NEGATED_CMP[type(op)])
                left = right
        elif isinstance(node, ast.BoolOp):
            word = b"and" if isinstance(node.op, ast.And) else b"or"
            other = "or" if word == b"and" else "and"
            for a, b in zip(node.values, node.values[1:], strict=False):
                s = off(a.end_lineno, a.end_col_offset)
                e = off(b.lineno, b.col_offset)
                m = re.search(rb"\b" + word + rb"\b", data[s:e])
                if m:
                    add("swap-boolean-operator", a.end_lineno, s + m.start(), s + m.end(), other)
        elif isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            s, e = node_span(node)
            os_, oe = node_span(node.operand)
            add("remove-not", node.lineno, s, e, b"(" + data[os_:oe] + b")")
        elif isinstance(node, ast.Constant):
            s, e = node_span(node)
            v = node.value
            if isinstance(v, bool):
                add("flip-boolean", node.lineno, s, e, "False" if v else "True")
            elif isinstance(v, (int, float)) and not isinstance(v, bool):
                add("number-plus-one", node.lineno, s, e, repr(v + 1))
            elif isinstance(v, str):
                add("empty-string", node.lineno, s, e, '""' if v else '"XX"')
        elif isinstance(node, ast.JoinedStr):
            s, e = node_span(node)
            add("empty-fstring", node.lineno, s, e, '""')
        if isinstance(node, (ast.If, ast.While, ast.IfExp)) \
                and isinstance(node.test, (ast.Name, ast.Attribute, ast.Call, ast.Subscript)) \
                and not _inside(node.test, skip):
            s, e = node_span(node.test)
            add("negate-condition", node.test.lineno, s, e, b"not (" + data[s:e] + b")")

    # Every mutant must still parse, and must change the program.
    original_dump = ast.dump(module)
    by_line: dict[int, list[Mutant]] = {}
    for m in found:
        mutated = data[: m.start] + m.replacement + data[m.end:]
        try:
            if ast.dump(ast.parse(mutated)) == original_dump:
                continue
        except SyntaxError:
            continue
        by_line.setdefault(m.line, []).append(m)
    for ms in by_line.values():
        ms.sort(key=lambda m: (PRIORITY.index(m.op), m.start))
    return by_line


def line_text(data: bytes, line: int) -> str:
    lines = data.decode("utf-8", "replace").splitlines()
    return lines[line - 1].strip() if 0 < line <= len(lines) else ""


# ---------------------------------------------------------------------------
# Running the tests.
# ---------------------------------------------------------------------------
def default_test_cmd(tree: Path) -> str:
    pytest = "python -m pytest -x -q -p no:cacheprovider -p no:randomly -o addopts="
    if (tree / "pyproject.toml").exists() and _which("uv"):
        return f"uv run --no-sync {pytest}"
    return "python3 -m pytest -x -q -p no:cacheprovider -p no:randomly -o addopts="


def _which(name: str) -> bool:
    return any(os.access(os.path.join(p, name), os.X_OK)
               for p in os.environ.get("PATH", "").split(os.pathsep) if p)


def run_tests(tree: Path, cmd: str, timeout: float) -> tuple[str, float]:
    env = dict(os.environ)
    for k in ("UV_OFFLINE", "UV_CACHE_DIR"):     # what lane.sh and merge-check strip
        env.pop(k, None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    started = time.monotonic()
    proc = subprocess.Popen(cmd, shell=True, cwd=tree, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        rc = proc.wait(timeout=max(timeout, 1))
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        return "timeout", time.monotonic() - started
    return ("survived" if rc == 0 else "killed"), time.monotonic() - started


def drop_bytecode(path: Path) -> None:
    cache = path.parent / "__pycache__"
    if cache.is_dir():
        for pyc in cache.glob(path.stem + ".*.pyc"):
            try:
                pyc.unlink()
            except OSError:
                pass


def tracked_state(tree: Path) -> str:
    return git(tree, "status", "--porcelain", "--untracked-files=no")


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--tree", required=True)
    ap.add_argument("--base-sha", required=True)
    ap.add_argument("--budget", type=float, default=420)
    ap.add_argument("--test-cmd", default="")
    ap.add_argument("--max-per-line", type=int, default=4)
    try:
        args = ap.parse_args()
    except SystemExit as e:
        sys.exit(2 if e.code else 0)
    if not args.base_sha.strip():
        print("--base-sha is empty", file=sys.stderr)
        sys.exit(2)
    started = time.monotonic()
    tree = Path(args.tree)
    if not (tree / ".git").exists():
        emit("unrunnable", f"{tree} is not a git checkout, so there is no diff to probe", 3)
    try:
        head = git(tree, "rev-parse", "HEAD").strip()
        git(tree, "rev-parse", "--verify", "--quiet", args.base_sha + "^{commit}")
        changed = changed_lines(tree, args.base_sha)
        before = tracked_state(tree)
    except subprocess.CalledProcessError as e:
        emit("unrunnable", f"git could not read the diff of {args.base_sha}..HEAD: "
             f"{(e.stderr or '').strip()[:200]}", 3)
    cmd = args.test_cmd or default_test_cmd(tree)
    common = {"base_sha": args.base_sha, "head_sha": head, "test_cmd": cmd,
              "budget_seconds": args.budget}

    originals: dict[str, bytes] = {}
    lines: list[Line] = []
    for path in sorted(changed):
        p = tree / path
        if not p.is_file():
            continue
        data = p.read_bytes()
        originals[path] = data
        for ln, ms in sorted(generate(path, data, changed[path]).items()):
            lines.append(Line(path, ln, line_text(data, ln), ms[: args.max_per_line]))
    changed_count = sum(len(v) for v in changed.values())
    if not lines:
        emit("pass", f"no mutable implementation line among {changed_count} changed "
             f"line(s) in {len(changed)} non-test Python file(s) — nothing to probe", 0,
             **common, lines={"changed": changed_count, "mutable": 0, "probed": 0},
             mutants={"run": 0, "killed": 0, "survived": 0, "timeout": 0},
             unobserved=[], partially_observed=[], not_fully_probed=[])

    # The unmutated baseline, with the very command every mutant will get.
    base_outcome, base_secs = run_tests(tree, cmd, args.budget)
    if base_outcome != "survived":
        emit("unrunnable", f"the unmutated tree is {'too slow' if base_outcome == 'timeout' else 'red'} "
             f"under the probe's own test command ({cmd}) — a mutant's failure would say nothing, "
             f"so nothing here is a verdict on the work", 3, **common, baseline_seconds=round(base_secs, 1))
    per_mutant = max(30.0, base_secs * 3 + 10)

    def restore_all(*_):
        for path, data in originals.items():
            target = tree / path
            if target.read_bytes() != data:
                target.write_bytes(data)
            drop_bytecode(target)

    def on_signal(signum, _frame):
        restore_all()
        sys.exit(128 + signum)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    counts = {"run": 0, "killed": 0, "survived": 0, "timeout": 0}
    out_of_budget = False
    try:
        rank = 0
        while not out_of_budget:
            pending = [ln for ln in lines
                       if rank < len(ln.mutants)
                       and not any(m.outcome in ("killed", "timeout") for m in ln.mutants)]
            if not pending:
                break
            for ln in pending:
                remaining = args.budget - (time.monotonic() - started)
                if remaining < min(per_mutant, base_secs + 5):
                    out_of_budget = True
                    break
                m = ln.mutants[rank]
                target = tree / m.file
                data = originals[m.file]
                try:
                    target.write_bytes(data[: m.start] + m.replacement + data[m.end:])
                    drop_bytecode(target)
                    m.outcome, _ = run_tests(tree, cmd, min(per_mutant, remaining))
                finally:
                    target.write_bytes(data)
                    drop_bytecode(target)
                counts["run"] += 1
                counts[m.outcome] += 1
            rank += 1
    finally:
        restore_all()

    if tracked_state(tree) != before:
        emit("unrunnable", "the probe could not restore the tree it mutated, so its result "
             "cannot be trusted", 3, **common)

    unobserved, partial, not_full = [], [], []
    probed = 0
    for ln in lines:
        outcomes = [m.outcome for m in ln.mutants]
        if all(o == "not-run" for o in outcomes):
            not_full.append(f"{ln.file}:{ln.line}")
            continue
        probed += 1
        if any(o in ("killed", "timeout") for o in outcomes):
            survivors = [m.mutation for m in ln.mutants if m.outcome == "survived"]
            if survivors:
                partial.append({"file": ln.file, "line": ln.line, "survived": survivors})
        elif all(o == "survived" for o in outcomes):
            unobserved.append({
                "file": ln.file, "line": ln.line, "source": _short(ln.source, 100),
                "mutants": [{"op": m.op, "mutation": m.mutation} for m in ln.mutants],
                "action": "add or tighten a test that fails when this line changes — "
                          "every mutation of it above left the whole suite green",
            })
        else:
            not_full.append(f"{ln.file}:{ln.line}")
    elapsed = round(time.monotonic() - started, 1)
    summary = {"changed": changed_count, "mutable": len(lines), "probed": probed}
    extra = dict(common, baseline_seconds=round(base_secs, 1), elapsed_seconds=elapsed,
                 lines=summary, mutants=counts, unobserved=unobserved,
                 partially_observed=partial, not_fully_probed=not_full)
    budget_note = (f"; budget ended with {len(not_full)} line(s) not fully probed"
                   if not_full else "")
    if probed == 0:
        emit("unrunnable", f"the budget ({args.budget:.0f}s) ended before any of {len(lines)} "
             f"mutable line(s) was probed — the unmutated suite alone took {base_secs:.0f}s", 3, **extra)
    if unobserved:
        emit("survived", f"{len(unobserved)} of {probed} probed changed line(s) are observed by no "
             f"test: every mutation left the suite green ({counts['run']} mutants run in "
             f"{elapsed:.0f}s{budget_note})", 1, **extra)
    emit("pass", f"every one of {probed} probed changed line(s) is observed by a test "
         f"({counts['run']} mutants run in {elapsed:.0f}s, {len(partial)} line(s) with "
         f"surviving mutants noted{budget_note})", 0, **extra)


if __name__ == "__main__":
    main()
