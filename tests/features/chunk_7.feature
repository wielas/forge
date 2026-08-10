Feature: CHUNK-7 frozen acceptance enforcement

  Scenario: Block a changed feature hash
    Given a feature file hash differs from the planning manifest
    When prejudge runs on an implementation PR
    Then it blocks and names the changed file.

  Scenario: Allow step definitions
    Given only step definitions are added
    When prejudge runs
    Then the frozen-feature check passes.

  Scenario: Block self-amendment
    Given an implementation PR changes a feature and its manifest entry together
    When prejudge compares both against main
    Then the self-amendment still blocks.

  Scenario: Accept a prior planning amendment
    Given acceptance genuinely needs amendment
    When a human planning PR updates the feature and manifest on main
    Then a later implementation branch can start from the new hash.

  @real-source
  Scenario: Preserve real-source scoring
    Given a frozen contract names an external source
    When judge reviews it
    Then the `@real-source` scenario remains part of the scored acceptance surface.
