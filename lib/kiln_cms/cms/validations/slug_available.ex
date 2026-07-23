defmodule KilnCMS.CMS.Validations.SlugAvailable do
  @moduledoc """
  For root-served types (pages at `/<slug>`): rejects a slug equal to a
  router-owned first segment or another content type's URL prefix. Route order
  registers those before the catch-all `/:slug`, so such a record would exist
  but be permanently unreachable (a page slugged "blog" shadowed by the
  `/blog` section). Auto-derived slugs sidestep these via
  `Slugs.ensure_unique/2`; this catches explicitly typed ones with a clear
  error instead of silent shadowing.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @impl true
  def validate(changeset, _opts, _context) do
    slug = Ash.Changeset.get_attribute(changeset, :slug)

    if Ash.Changeset.changing_attribute?(changeset, :slug) and is_binary(slug) and
         ContentTypes.root_served?(changeset.resource) and
         slug in Slugs.taken_root_segments(org_id(changeset)) do
      {:error,
       field: :slug, message: "conflicts with the /#{slug} section URL — pick another slug"}
    else
      :ok
    end
  end

  defp org_id(changeset) do
    (Ash.Resource.Info.attribute(changeset.resource, :org_id) &&
       Ash.Changeset.get_attribute(changeset, :org_id)) ||
      KilnCMS.Accounts.default_org_id()
  end
end
