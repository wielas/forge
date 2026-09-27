# Requirements — board digest

**Ambition:** tool
**Complexity budget:** 2 milestones, 4 chunks

## Mission

The operator reads what the board did yesterday from one paste-ready page,
without opening the board.

## Functional requirements

- FR-1 Read a snapshot of a Hermes board. *Accept:* an idle WAL board reads.
- FR-2 Emit one record per completed run. *Accept:* one run, one record.
- FR-3 Mark a run with no terminal event unavailable. *Accept:* null, not zero.
- FR-4 Fix the record's public shape. *Accept:* an unknown key fails validation.
- FR-5 Render the records to Markdown. *Accept:* byte-identical across locales.
- FR-6 Publish the digest atomically. *Accept:* no partial file on a failed rename.

## Non-functional requirements

- NFR-1 The record is byte-stable: the same snapshot yields the same bytes.

## Delight

- FR-5 — the digest pastes straight into a chat with no editing.

## Gold-plating pass

- cut: a web dashboard — the page is read once a day, a file does it.

## Out of scope

1. Writing to the board.
2. Any network publication.

## Open questions

- none

## Notes for architect

- The board is WAL; never open it read-only.
