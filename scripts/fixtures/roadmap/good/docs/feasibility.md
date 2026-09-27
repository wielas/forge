# Feasibility — board digest

| Component | Approach | Prior art | Spike | Verdict | Chunks | Tier | Cost | Call |
|---|---|---|---|---|---|---|---|---|
| Board reader | `cp` the WAL board, open the copy | `scripts/board-snapshot.sh` | `spikes/wal-snapshot` | proven | 1 | strong | one Codex chunk | keep |
| Record shape | JSON schema, field order fixed | none — the shape is ours | none | not-spiked | 1 | human | one interactive session | keep |
| Renderer and publisher | render, write a sibling, rename | stdlib `os.replace` | none | not-spiked | 1 | strong | one Codex chunk | keep |
| Web dashboard | static HTML | many | none | not-spiked | 2 | strong | two Codex chunks | cut |

## Decisions for you

- none — the one surprise (the WAL read) was spiked and holds.
