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

<a id="the-automation-builder-reads-as-steps-and-says-each-rule-back-as-a-sentence"></a>

- **The automation builder reads as steps and says each rule back as a
  sentence.** `/editor/automation` is now four numbered steps: when (content
  type and event, the events grouped as editorial changes, tasks and content
  health), do this, set it up, and name it. The reaction dropdown is a set of
  cards grouped as "Notify people", "Review & follow-up" and "Keep the site
  fresh", each with an icon and a line on what it does. While the rule is
  being built, the form shows it as one sentence, such as "When Post content
  is published, email team@example.com." The rules list shows that sentence
  in place of `post.published → send_email`, and a rule saved with no name is
  named by it.
