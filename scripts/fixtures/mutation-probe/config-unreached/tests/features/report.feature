Feature: Report options

  Scenario: the footer can be switched off
    Given two items
    When the report is rendered without a footer
    Then the report has no footer

  Scenario: the report can be limited
    Given two items
    When the report is rendered with a limit of 1
    Then the report lists 1 item

  Scenario: the report is rendered from config
    Given two items
    When the report is rendered from an empty config
    Then the report lists alpha
