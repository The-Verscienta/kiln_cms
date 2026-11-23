# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Added

<a id="flexible-media-reference"></a>

- **An item of a Flexible content field can hold a single image (Media) or a link to one record (Reference), picked inside the item's card (#2282).**
  - **Admin.** A sub-field under an item type offers the kinds **Media** and
    **Reference**; a reference asks which types it **Links to** and has no
    cap, delete rule, reverse side or details. Plain groups don't take them
    yet.
  - **Editor.** The card shows the image picker and the record search at any
    nesting depth. What is saved is the same snapshot a top-level field keeps,
    rebuilt from the record on every save (a snapshot sent by a client is
    never trusted); a record the editor cannot read is refused at the item's
    path (`sections[0].cta`).
  - **Everywhere else.** A reader who cannot see the record gets `null` where
    its snapshot was, in the API and in the fired `:json` artifact; a renamed
    target, a re-processed image and a duplicate or locale copy all re-resolve
    inside items; `mix kiln.media.resnapshot` re-takes the images inside them.
    A reference inside an item is `on_target_delete: :keep` and uncapped; its
    edge is keyed by the definition path (`sections.hero.cta`), with no
    migration. The SQL reporting views already cut such a reference to
    `{id, type}` (#3057).
  - **Rollback.** The previous release rejects any object in an item's
    sub-field, so re-saving a record that holds an item image or reference
    there fails validation (reads work). Roll forward, or delete the
    sub-field.
  Record: [ADR 0065](../decisions/0065-a-flexible-field-keeps-its-mixed-items-inline-and-its-item-types-are-field-definitions.md#media-and-reference-inside-items-pr-3-2282);
  guide: [Build flexible content in the admin](../extending-content.md#build-flexible-content-in-the-admin).
