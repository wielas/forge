Feature: CHUNK-4 live metadata sweep

  Scenario: Require a cutoff before reading a board
    Given no RFC3339 `SINCE` value
    When `make metadata-live` runs
    Then it refuses before reading a board.

  @real-source
  Scenario: Count expected producers
    Given post-cutoff completed rows from every contracted profile
    When the sweep runs
    Then valid envelopes are counted by profile and schema.

  Scenario: Classify malformed metadata
    Given a board contains nested metadata, null metadata, and a cross-profile envelope
    When the sweep runs
    Then every bad row is named and classified as invalid or unjudged.

  Scenario: Reject an invalid model-authored block reason
    Given a model-authored block reason outside `blocked_reason_pattern`
    When the sweep runs
    Then it fails and prints the task, run, and reason.

  Scenario: Ignore pre-cutoff rows explicitly
    Given rows predate `SINCE`
    When the sweep runs
    Then they are ignored and reported separately from valid rows.
