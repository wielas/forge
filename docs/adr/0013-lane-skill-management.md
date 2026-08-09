# ADR-0013: Retain lane skill management behind write approval

**Status:** accepted · 2026-08-09

## Context

The `forge-codex-lane` profile needs Hermes's built-in `skills` toolset to load
the `forge-lane` protocol. That toolset also exposes `skill_manage`, which can
write external-directory skills. With `skills.write_approval` enabled, the same
call returns successfully after staging a pending proposal; it does not block the
worker or apply the edit.

Hermes 0.19.0 accepts either a built-in toolset name or an MCP
`server:tool` name in `hermes tools disable`. `skill_manage` is neither: it is a
member of the built-in `skills` toolset. The CLI therefore cannot disable only
`skill_manage`; disabling `skills` would also remove the mechanism that loads
the lane's required protocol.

## Decision

Retain the `skills` toolset for `forge-codex-lane` and enforce
`skills.write_approval=true` in generated profile configuration and its runtime
readback. The boundary is configuration, checked by `make verify`, not a SOUL
instruction.

The residual capability is explicit: an unattended lane may invoke
`skill_manage` and stage a proposed skill rewrite under Hermes's pending review
area. It cannot apply that rewrite without a human approval. A successful staged
tool result therefore means "proposal recorded," not "methodology changed."

## Consequences

- The lane can continue loading `forge-lane` from the checked-out `skills/`
  directory.
- A compromised or mistaken lane can create review noise and may continue while
  believing its staged proposal landed. It cannot change the active skill bytes
  through that call without approval.
- `hermes/profiles-bootstrap.sh` remains the source of truth and verifies
  `skills.write_approval` after writing every profile config. Removing that
  readback or setting the value false is a failing conformance case.
- If Hermes later supports disabling one built-in tool independently, revisit
  this ADR; do not disable the whole `skills` toolset as a substitute.

## Rejected

- **Disable the `skills` toolset.** This removes `skill_manage`, but also removes
  the protocol the lane exists to execute.
- **Rely on the SOUL to forbid writes.** Prompt text is not an enforcement
  boundary (ADR-0003), and the real tool has already written external-dir skills
  when approval was off.
- **Treat staging as no capability.** A staged proposal is durable write-side
  activity and the worker receives success immediately; hiding that residual
  capability would make the boundary sound stronger than it is.
