Feature: CHUNK-2 Touches widening

  Scenario: Report an added path
    Given the head contract adds a path absent from the base contract
    When prejudge runs
    Then `touches-widened` warns with that path even when the implementation diff is inside the head list.

  Scenario: Ignore a removed path
    Given the head contract removes a path
    When prejudge runs
    Then the removal is not reported as widening.

  Scenario: Pass an unchanged in-scope contract
    Given the contract is unchanged and the implementation stays inside it
    When prejudge runs
    Then both `touches` and `touches-widened` pass.

  Scenario: Share the process-document exemption
    Given a process-doc exemption is added to `Touches`
    When prejudge compares the contracts
    Then the shared exemption policy is applied and no second exemption list is introduced.
