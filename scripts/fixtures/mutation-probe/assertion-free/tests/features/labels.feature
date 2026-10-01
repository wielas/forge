Feature: Label normalisation

  Scenario: a label is normalised
    Given the label "  Hello   World "
    When it is normalised
    Then the result is "hello-world"

  Scenario: an empty label is untitled
    Given the label "   "
    When it is normalised
    Then the result is "untitled"
