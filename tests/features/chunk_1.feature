Feature: CHUNK-1 control-plane references and pins

  Scenario: Resolve every skill section reference
    Given every `<skill> §<n>` reference in a Forge skill
    When the CLI suite runs
    Then each target heading resolves in the named skill.

  Scenario: Name a renamed section
    Given a referenced section is renamed
    When the CLI suite runs
    Then it fails and names the source reference and missing heading.

  Scenario: Check pins offline
    Given the two checked-in Codex pin statements agree
    When the offline CLI suite runs
    Then it passes without reading a home-directory config.

  Scenario: Report live pin drift
    Given the live Codex pin differs from the checked-in model-and-effort pair
    When the config suite runs
    Then it fails and prints both values.

  @real-source
  Scenario: Retain the supported Hermes skill boundary
    Given Hermes cannot disable only `skill_manage`
    When the profile policy is read
    Then the ADR retains the `skills` toolset behind enforced `skills.write_approval=true` and names the residual staged-write capability.
