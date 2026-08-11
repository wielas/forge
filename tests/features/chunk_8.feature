Feature: CHUNK-8 root-only bootstrap

  @real-source
  Scenario: Create only the graph root
    Given a valid graph with one root
    When bootstrap runs with `--root-only`
    Then it creates only that root card.

  Scenario: Refuse multiple roots
    Given a graph has multiple roots
    When root-only bootstrap runs
    Then it fails before any card is created.

  Scenario: Extend a prior root-only launch
    Given root-only already created the root
    When full bootstrap runs
    Then the same idempotency key maps the root and every remaining parent is attached atomically.

  Scenario: Reconcile only the created set
    Given root-only mode
    When parent-count reconciliation runs
    Then it checks the created set without weakening full mode's declared-edge assertion.
