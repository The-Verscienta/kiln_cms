# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="automation-rules-are-set-up-with-ordinary-fields-instead-of-a-json-box"></a>

- **Automation rules are set up with ordinary fields instead of a JSON box.**
  The "Action config (JSON)" textarea on `/editor/automation` is gone. Picking
  a reaction now shows one input per setting it takes, such as an email field
  for "Send to", a network picker for social posts, a person picker for task
  assignees, and a toggle for `allow_egress`, with the required ones marked.
  The intelligence reactions show the fields for the chosen "Send findings as"
  option (email, comment or task) and hide the rest. Template fields have
  chips that insert `{{title}}` and the other placeholders. The inputs are
  generated from `ActionConfig`'s shape table, so the form cannot offer a key
  the save refuses. The validation itself is unchanged and still refuses the
  string `"true"` for `allow_egress` from the API and seeds. Stored rules need
  no migration.
