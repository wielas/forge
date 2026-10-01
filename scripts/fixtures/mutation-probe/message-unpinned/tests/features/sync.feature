Feature: Sync paused

  Scenario: nothing piles up in silence
    Given two items and syncing paused
    When syncing runs
    Then nothing is synced and nothing is queued

  Scenario: syncing on syncs every item
    Given two items and syncing on
    When syncing runs
    Then both items are synced
