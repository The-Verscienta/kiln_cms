defmodule KilnCMS.CMS.Changes.BustBranding do
  @moduledoc """
  Invalidates a site's cached `%KilnCMS.Branding{}` after any `SiteBranding`
  write, so a settings save is visible on the next request instead of waiting
  out the TTL.

  Also busts `llms.txt`, which bakes the site name into its cached *body*.

  And purges the site's CDN key (`KilnCMS.CDN.purge_site/1`) when a value
  `GET /api/site` answers may have changed (#2577): that response is publicly
  cached per URL, and a branding save changes it without anything being
  published. Only then, not on every write: the nightly app-icon re-verify
  (`:reverify_app_icon`) updates every row with an icon, and purging every
  site's CDN each night for a field no cached response carries would throw away
  the whole cache for nothing. A destroy (the settings page's reset) and the
  first save always purge.

  The per-record published-content cache is deliberately **not** cleared: it
  holds `%{record, blocks, translations}`, not rendered HTML — the layout
  re-reads branding every request — so a rare settings save must not flush every
  org's content cache.
  """
  use Ash.Resource.Change

  # The `SiteBranding` columns `KilnCMSWeb.SiteDefaults` reads. A key added
  # there adds its column here.
  @public_fields [:site_name, :twitter_site, :social_image_url]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&remember_previous/1)
    # `after_transaction` for the reason `BustCodeInjection` gives: the branding
    # bust is a cluster-wide broadcast now, and one sent before the commit lets
    # a remote node re-cache the pre-write value under a fresh TTL.
    |> Ash.Changeset.after_transaction(fn changeset, result ->
      # A destroy may answer a bare `:ok`; the row it removed is the data.
      if match?({:ok, _}, result) or result == :ok, do: bust(changeset, result)
      result
    end)
  end

  defp bust(changeset, result) do
    org_id = org_id(changeset, result)

    KilnCMS.Cache.bust_branding(org_id)
    KilnCMS.Cache.bust_llms(org_id)
    # Delivery ETag folds head generation (#1079): branding lands in `<head>`.
    KilnCMS.Cache.bump_head_generation(org_id)

    if public_change?(changeset, result), do: KilnCMS.CDN.purge_site(org_id)
  end

  # The row as it was before this write, for `public_change?/2`. An update or
  # destroy has it as its data. A `:save` is an upsert, so its data is a blank
  # struct whatever the table holds; read the site's row, as the resolver does
  # (`KilnCMS.Branding`: a system read, world-readable by policy).
  defp remember_previous(%{action_type: :create} = changeset) do
    previous =
      case Ash.Changeset.get_attribute(changeset, :org_id) do
        org_id when is_binary(org_id) -> current_row(org_id)
        # Never a tenant-less read: on the fail-open build it would answer some
        # other site's row.
        _no_org -> nil
      end

    Ash.Changeset.put_context(changeset, :branding_previous, previous)
  end

  defp remember_previous(changeset),
    do: Ash.Changeset.put_context(changeset, :branding_previous, changeset.data)

  defp current_row(org_id) do
    case KilnCMS.CMS.list_site_branding(
           tenant: org_id,
           actor: KilnCMS.OrgSettings.system(:branding),
           authorize_with: :error
         ) do
      {:ok, [row | _]} -> row
      # No row yet: this save creates one. A failed read is treated the same,
      # so the purge errs toward running.
      _none_or_error -> nil
    end
  end

  defp public_change?(changeset, result) do
    previous = changeset.context[:branding_previous]

    case result do
      {:ok, %{} = record} when not is_nil(previous) and changeset.action_type != :destroy ->
        Enum.any?(@public_fields, &(Map.get(previous, &1) != Map.get(record, &1)))

      _created_or_destroyed ->
        true
    end
  end

  defp org_id(_changeset, {:ok, %{org_id: org_id}}) when is_binary(org_id), do: org_id

  defp org_id(changeset, _result),
    do: changeset.data.org_id || Ash.Changeset.get_attribute(changeset, :org_id)
end
