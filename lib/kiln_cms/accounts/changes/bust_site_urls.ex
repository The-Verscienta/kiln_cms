defmodule KilnCMS.Accounts.Changes.BustSiteUrls do
  @moduledoc """
  Moves what a site's absolute URLs were cached under when an organization's
  `slug` or `custom_domain` changes (#3194).

  Canonical, hreflang and Open Graph URLs come from `KilnCMSWeb.Tenant.base_url/1`
  at render time, and neither field is an input of the delivery `ETag`, so a
  revalidating client kept a `304` whose absolute URLs named the old host. This:

    * drops the org's host resolutions (`KilnCMS.Cache.Hosts`) under its old
      and new hosts, on every node. A request holds the org struct its host
      resolved to, for up to five minutes, so without this a page rendered
      after the bump below would still name the old host, under the new `ETag`;
    * bumps the head generation (`KilnCMS.Cache.bump_head_generation/1`) that
      the `ETag` folds in;
    * drops the sitemaps, feeds and `llms.txt`, which bake the base URL into
      their cached bodies;
    * purges the site's CDN key.

  Decided by comparing the row before and after, not with
  `Ash.Changeset.changing_attribute?/2`: `NormalizeOrgSlug` rewrites the slug,
  and a value equal to the stored one is no change at all.

  `after_transaction`, as `KilnCMS.CMS.Changes.BustBranding` explains: the bump
  is a cluster-wide put, and one sent before the commit lets a remote node
  render the old URLs under the new token.
  """
  use Ash.Resource.Change

  alias KilnCMS.Cache

  @url_fields [:slug, :custom_domain]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      with {:ok, %{id: org_id} = org} <- result,
           true <- Enum.any?(@url_fields, &(Map.get(changeset.data, &1) != Map.get(org, &1))) do
        bust(changeset.data, org, org_id)
      end

      result
    end)
  end

  defp bust(previous, org, org_id) do
    hosts =
      Enum.uniq(
        KilnCMSWeb.Tenant.host_cache_keys(previous) ++ KilnCMSWeb.Tenant.host_cache_keys(org)
      )

    # Hosts first, then the bump. Both go out from this process on the same
    # ClusterBust topic, and PubSub keeps one sender's messages in order, so no
    # node sees the new token while it can still resolve the old org struct.
    Cache.ClusterBust.broadcast_in(Cache.Hosts.cache_name(), hosts)
    Cache.bump_head_generation(org_id)
    Cache.bust_sitemap(org_id)
    Cache.bust_all_feeds(org_id)
    Cache.bust_llms(org_id)
    KilnCMS.CDN.purge_site(org_id)
  end
end
