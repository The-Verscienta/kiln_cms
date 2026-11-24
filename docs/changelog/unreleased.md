# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="condition-text-ops"></a>

- **Conditional fields can match text (#3270).** A **Show when** or **Required when** test in `/editor/fields` now offers **contains**, **does not contain**, **starts with** and **ends with** when it reads a text, URL or choice field: "show **Download notes** when **File URL** ends with `.pdf`". In a rule these are the operators `contains`, `not_contains`, `starts_with` and `ends_with`, each with a non-blank string `value`.
  - **Matching ignores case and surrounding spaces.** Both sides are trimmed, as for `eq`, and lowercased. The editor's evaluator and the server agree on non-ASCII text too (a Greek word-final sigma folds to ς on both); one shared fixture holds them to it.
  - **Lists and non-text values.** On a multiple field a test holds when any item matches, so **does not contain** holds only when no item contains the text. An empty value contains nothing. A number, yes/no or date field cannot use these tests: the definition is refused, and so is retyping a field to a non-text type while a text test reads it.
  - **Additive.** No migration. An older release reading a rule with one of these operators treats it as a rule it cannot read: the field is shown and not required, and the definition cannot be saved until the rule is changed.
