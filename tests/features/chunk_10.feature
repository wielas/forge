Feature: CHUNK-10 launch-ledger reconciliation

  Scenario: Reconcile every touched finding
    Given every finding touched by this roadmap
    When the ledger is reconciled
    Then each status header agrees with executable evidence and names the closing chunk or remaining proof.

  Scenario: Separate landed and remaining work
    Given the old first-run roadmap mixes shipped and future work
    When it is reconciled
    Then landed tracks, remaining commands, and the operational run sequence are unambiguous.

  Scenario: Preserve bounded cleanup
    Given F80's out-of-bound worktrees
    When the operator guide describes cleanup
    Then it preserves the bounded unattended sweep and requires explicit review outside that bound.

  Scenario: Preserve prior dispositions
    Given F81 and F103 have prior dispositions
    When docs are updated
    Then the record is preserved and a superseding decision is linked rather than silently rewriting history.
