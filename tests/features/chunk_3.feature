Feature: CHUNK-3 deterministic diagnostics

  Scenario: Keep verify help content-anchored
    Given a new verify suite is appended
    When `verify.sh --help` runs
    Then the complete group list is printed without line-number pins.

  Scenario: Keep preflight help content-anchored
    Given preflight's header grows
    When `preflight.sh --help` runs
    Then its Usage and Exit sections remain complete.

  Scenario: Detect a WAL sidecar
    Given an end-to-end metrics read creates a WAL sidecar
    When the read-only case compares the source set
    Then it fails even if `kanban.db` bytes are unchanged.

  @real-source
  Scenario: Inspect all live boards deterministically
    Given multiple live boards exist
    When the live-schema check runs
    Then every selected board is named and checked deterministically rather than choosing `ls | head -1`.

  Scenario: Describe reachability honestly
    Given a finite acyclic graph has one root
    When `reachable` reports pass
    Then ADR-0012 identifies it as diagnostic evidence and not an independent detector.
