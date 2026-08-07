defmodule KilnCMS.CMS.Validations.MenuItemDestination do
  @moduledoc """
  A menu item's destination must match its `link_type`: a `:content` item needs
  a known content type and a target id, a `:url` item needs a URL that survived
  `Changes.SanitizeMenuItemLink`, and a `:none` item needs neither.

  Runs after that change (declaration order), so "no URL" here means *no usable
  URL* — an unsafe `javascript:` href has already been nil'd, and the editor is
  told the destination is missing rather than being handed a stored link the
  delivery layer would refuse to serve.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS.ContentTypes

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :link_type) do
      :content -> validate_content(changeset)
      :url -> validate_url(changeset)
      _none -> :ok
    end
  end

  defp validate_content(changeset) do
    type = Ash.Changeset.get_attribute(changeset, :target_type)
    id = Ash.Changeset.get_attribute(changeset, :target_id)

    cond do
      is_nil(id) ->
        {:error, field: :target_id, message: "pick the content this item links to"}

      is_nil(type) or is_nil(ContentTypes.get(type, org_id(changeset))) ->
        {:error, field: :target_type, message: "isn't a content type on this site"}

      true ->
        :ok
    end
  end

  defp validate_url(changeset) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      url when is_binary(url) and url != "" ->
        :ok

      _blank ->
        {:error,
         field: :url, message: "enter a link — an absolute http(s) URL, a site path, or mailto:"}
    end
  end

  defp org_id(changeset) do
    Ash.Changeset.get_attribute(changeset, :org_id) || KilnCMS.Accounts.default_org_id()
  end
end
