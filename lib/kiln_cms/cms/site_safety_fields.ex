defmodule KilnCMS.CMS.SiteSafetyFields do
  @moduledoc """
  Which fields of which content types are *safety-relevant* on this site: an
  edit that changes one of them to live content carries a severity
  (`critical`, `notable` or `routine`), stored on that edit's version row. See
  `KilnCMS.CMS.Severity` for the rule and `KilnCMS.CMS.Changes.RecordChangeSeverity`
  for the enforcement.

  `fields` is a map from a content type **name** (`"post"`, a dynamic type's own
  name — the spelling `KilnCMS.CMS.ContentTypes.type_name_for/1` returns) to the
  list of field names that count: a built-in attribute (`"title"`, `"blocks"`,
  `"seo_description"`, ...) or a custom field's name. `"*"` in the list means
  every editorial field of the type.

  ## Absence means nothing is safety-relevant

  No row, an empty map, or a type with no entry: no edit is asked for a severity
  and none is recorded. A site that never opened the settings starts where every
  install was before this existed.

  Write it through `KilnCMS.CMS.save_site_safety_fields/2` (an upsert, so the
  whole map is replaced — send every type the site wants listed).
  """
  # The shared one-row-per-org shape comes from `KilnCMS.CMS.OrgSettings`.
  # Editors read it (the editor explains why it is asking for a severity);
  # changing what counts as safety-relevant is an admin act. The system actor
  # may `read` it for the same reason `SiteEditorialSettings` admits it: the
  # write that asks may be a scheduled publish or an API key, with no person
  # reading. `save` is not admitted.
  use KilnCMS.CMS.OrgSettings,
    table: "site_safety_fields",
    accept: [:fields],
    read: :editor,
    update?: false,
    system_actions: [read: :cms_settings]

  # Bounds, so a settings value can never make the per-write diff unbounded.
  @max_types 200
  @max_fields 200

  changes do
    change KilnCMS.CMS.Changes.BustSafetyFields, on: [:create, :update, :destroy]
  end

  validations do
    validate {KilnCMS.CMS.Validations.SafetyFieldsShape,
              max_types: @max_types, max_fields: @max_fields},
             on: [:create, :update]
  end

  attributes do
    attribute :fields, :map do
      default %{}
      allow_nil? false
      public? true
    end
  end
end
