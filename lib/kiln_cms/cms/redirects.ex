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
  Where a retired `path` in `locale` now lives: `%{to: current_path, type:,
  slug:, id:}`, or `nil` when no redirect matches / the target is no longer
  published.
  """
  @spec resolve(String.t(), String.t(), Ash.UUID.t()) :: map() | nil
  def resolve(path, locale, org_id) do
    with [redirect] <-
           CMS.list_redirects!(
             authorize?: false,
             tenant: org_id,
             query: [filter: [path: path, locale: locale], limit: 1]
           ),
         ct when not is_nil(ct) <- ContentTypes.get(redirect.target_type, org_id),
         %{} = target <- published_target(ct, redirect.target_id, org_id),
         to when to != path <- Slugs.public_path_for(ct, target) do
      %{to: to, type: to_string(ct.type), slug: target.slug, id: redirect.target_id}
    else
      _ -> nil
    end
  end

  # The target's current URL fields, only while it is still published. The
  # destination is its canonical path — a `path_alias` (#485) when set.
  defp published_target(ct, target_id, org_id) do
    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id == ^target_id and state == :published)
    |> Ash.Query.select([:slug, :path_alias])
    |> Ash.read_one!(authorize?: false, tenant: org_id)
  end
end
