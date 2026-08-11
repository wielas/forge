Feature: CHUNK-9 product commissioning

  @real-source
  Scenario: Record all launch prerequisites
    Given a clean durable project with a protected remote
    When `make commission` runs
    Then it executes the paid Codex probe, preflight, roadmap check, and launch prerequisites into one timestamped report.

  Scenario: Propagate prerequisite failure
    Given a prerequisite exits nonzero
    When commissioning finishes
    Then the report names that check and the command exits nonzero.

  Scenario: Preserve advisory warnings
    Given roadmap-check emits advisory warnings
    When commissioning records it
    Then the report preserves WARN rather than relabelling it PASS.

  @real-source
  Scenario: Require an enforceable merge gate
    Given the repository is private without an enforceable merge gate
    When commissioning checks protection
    Then it refuses regardless of repository visibility labels.

  Scenario: Leave the project and board unchanged
    Given commissioning succeeds
    When the operator inspects the project
    Then tracked files and the board are unchanged and evidence lives under ignored `.forge/` state.
