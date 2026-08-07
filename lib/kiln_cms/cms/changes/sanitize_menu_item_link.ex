defmodule KilnCMS.CMS.Changes.SanitizeMenuItemLink do
  @moduledoc """
  Runs a menu item's `url` through `KilnCMS.HTMLSanitizer.safe_href/1`, and
  clears the fields the item's `link_type` doesn't use.

  Navigation is served to headless front ends as data, and a front end renders
  a menu item's URL straight into an `href` — so this value has the same threat
  profile as a rich-text link (#832), and gets the same single policy. A
  `javascript:` destination is refused rather than stored: leaving it to the
  consumer to filter would make every consumer responsible for a rule Kiln
  already owns.

  Clearing the unused fields is the other half. An item switched from `:url` to
  `:content` that kept its old `url` would carry two destinations, and any
  reader picking the "wrong" one would follow a link the editor believes they
  deleted.
  """
  use Ash.Resource.Change

  alias KilnCMS.HTMLSanitizer

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :link_type) do
      :url -> changeset |> sanitize_url() |> clear([:target_type, :target_id])
      :content -> clear(changeset, [:url])
      _none -> clear(changeset, [:url, :target_type, :target_id])
    end
  end

  defp sanitize_url(changeset) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      nil ->
        changeset

      url ->
        # `nil` out an unsafe href rather than silently keeping the raw value;
        # the destination validation then reports it as a missing URL, which is
        # the truthful message for "this destination isn't usable".
        Ash.Changeset.force_change_attribute(changeset, :url, HTMLSanitizer.safe_href(url))
    end
  end

  defp clear(changeset, fields) do
    Enum.reduce(fields, changeset, &Ash.Changeset.force_change_attribute(&2, &1, nil))
  end
end
