defmodule KilnCMS.CMS.Redirects do
  @moduledoc """
  Delivery-side resolution of retired public paths (`CMS.Redirect` rows).

  A redirect stores the record that vacated the path, not a frozen
  destination, so `resolve/3` computes the record's **current** published URL
  at request time — renames never chain, and an unpublished/trashed target
  simply stops resolving (the caller 404s as before).
  """

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  @doc """
  The current public path to 301 to for a retired `path` in `locale`, or `nil`
  when no redirect matches / the target is no longer published.
  """
  @spec resolve(String.t(), String.t(), Ash.UUID.t()) :: String.t() | nil
  def resolve(path, locale, org_id) do
    with [redirect] <-
           CMS.list_redirects!(
             authorize?: false,
             tenant: org_id,
             query: [filter: [path: path, locale: locale], limit: 1]
           ),
         ct when not is_nil(ct) <- ContentTypes.get(redirect.target_type, org_id),
         slug when is_binary(slug) <- published_slug(ct, redirect.target_id, org_id),
         to when to != path <- Slugs.public_path(ct, slug) do
      to
    else
      _ -> nil
    end
  end

  # The target's current slug, only while it is still published.
  defp published_slug(ct, target_id, org_id) do
    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id == ^target_id and state == :published)
    |> Ash.Query.select([:slug])
    |> Ash.read_one!(authorize?: false, tenant: org_id)
    |> case do
      nil -> nil
      record -> record.slug
    end
  end
end
