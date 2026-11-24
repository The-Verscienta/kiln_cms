defmodule KilnCMS.SectionLayoutFixtures do
  @moduledoc """
  Section layouts (`KilnCMS.CMS.FieldSection`) that no field carries: the
  rows an older release left (#3060, #3061).

  The resource's create refuses a section no top-level field of its owner is
  in, so such a row is seeded past it with `Ash.Seed`, the way 1.9.x and
  1.10.x stored them. A layout some field does carry is made through
  `KilnCMS.CMS.create_field_section/2`, after its field.
  """

  @doc """
  Seeds a layout with no carrier. Takes the resource's attributes plus
  `:org_id` (default: the default org); the owner defaults to `:page`.
  """
  @spec orphan_layout!(map()) :: struct()
  def orphan_layout!(attrs) do
    owner =
      if Map.has_key?(attrs, :type_definition_id),
        do: %{content_type: nil},
        else: %{content_type: :page}

    Ash.Seed.seed!(
      KilnCMS.CMS.FieldSection,
      %{org_id: KilnCMS.Accounts.default_org_id(), display: :tab, initially: :auto}
      |> Map.merge(owner)
      |> Map.merge(attrs)
    )
  end
end
