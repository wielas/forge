Feature: CHUNK-6 planning-time acceptance freeze

  Scenario: Emit contract-matched acceptance
    Given a chunk contract
    When `/roadmap` finishes
    Then its `Acceptance` field names an existing `tests/features/chunk_<id>.feature` whose Given/When/Then steps match the contract.

  Scenario: Plan real-source coverage
    Given a contract declares each external source and its scenario index
    When `/roadmap` finishes
    Then every declared source maps to a matching `@real-source` scenario.

  Scenario: Hash every planned feature
    Given all planned feature files exist
    When the freeze command runs
    Then it writes deterministic path and SHA-256 entries to `contract-freeze.json`.

  Scenario: Name a missing feature
    Given a missing feature file
    When the freeze command runs
    Then it fails and names the chunk and expected path.
