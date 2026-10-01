Feature: Branch slugs

  Scenario Outline: a title becomes a slug
    Given the title "<title>"
    When it is slugified
    Then the slug is "<slug>"

    Examples:
      | title                  | slug         |
      | Sync Engine            | sync-engine  |
      | Fix: the CLI !         | the-cli      |
      | Hello wonderful worlds | hello-wonder |
      | Twelve chars           | twelve-chars |
      | abcdefghijk lmn        | abcdefghijk  |
      | !!!                    | untitled     |
