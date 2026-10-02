defmodule KilnCMS.I18n.Calculations.InheritedFields do
  @moduledoc """
  The `inherited_fields` calculation on every content type (#1327): what a
  locale variant inherits along the site's fallback chain for the fields its
  type marks `:fallback`, as `KilnCMS.I18n.FieldFallback.inherited_values/2`
  returns it.

  The headless counterpart of what the fired artifact and the public page do:
  JSON:API (`fields[page]=title,inherited_fields`) and GraphQL
  (`inheritedFields`) clients ask for it explicitly. Neither serves it by
  default, so a response that does not ask is byte-identical to what it was,
  and the row's own `excerpt`, `custom_fields` and SEO fields keep reporting
  exactly what the variant stores.

  It adds no grant: only published, unlocked siblings readable by at least
  everyone who can read this row are inherited from (see `FieldFallback`).
  """
  use Ash.Resource.Calculation

  alias KilnCMS.I18n.FieldFallback

  @impl true
  def load(query, _opts, _context) do
    Enum.filter(
      [:slug, :locale, :audience, :custom_fields, :type_definition_id] ++
        KilnCMS.I18n.FieldLocalization.fallbackable_attributes(),
      &Ash.Resource.Info.attribute(query.resource, &1)
    )
  end

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, &FieldFallback.inherited_values/1)
  end
end
