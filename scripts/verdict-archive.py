#!/usr/bin/env python3
"""Keep each review action's original payload without replacing earlier rounds."""
import datetime
import json
import os
from pathlib import Path
import sys
import tempfile


def main():
    if len(sys.argv) != 6:
        raise ValueError("usage: verdict-archive.py ROOT BOARD CHUNK ACTION PAYLOAD")
    root, board, chunk, action, source = sys.argv[1:]
    with open(source, encoding="utf-8") as stream:
        payload = json.load(stream)
    record = {"schema": "forge.review-evidence.v1", "board": board, "chunk": chunk,
              "action": action, "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "payload": payload}
    directory = Path(root) / "history"
    directory.mkdir(parents=True, exist_ok=True)
    # Exclusive creation prevents concurrent reviews from replacing each other.
    fd, name = tempfile.mkstemp(prefix=".review-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, ensure_ascii=False, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        destination = Path(name).with_name(Path(name).name[1:-4] + ".json")
        os.link(name, destination)
    finally:
        os.unlink(name)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        print(f"verdict archive: {exc}", file=sys.stderr)
        sys.exit(1)
