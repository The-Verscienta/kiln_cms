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
    # Under the policies, actorless (#1659): `Redirect` rows are world-readable
    # — delivery serves the same mapping to anyone who hits the old URL.
    with [redirect] <-
           CMS.list_redirects!(
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
  #
  # `authorize?: false`, justified (#1402's content-read argument): the read
  # filters to `state == :published` itself and selects only `slug` and
  # `path_alias` — the target's public address, which the 301 discloses
  # anyway. Reading it as the anonymous visitor would drop the redirect for
  # audience-gated or locked content, whose own page then answers the visitor
  # with its gate; a `SystemActor` content-read grant would hand every system
  # caller the whole corpus, drafts included.
  defp published_target(ct, target_id, org_id) do
    Slugs.storage_resource(ct)
    |> Ash.Query.filter(id == ^target_id and state == :published)
    |> Ash.Query.select([:slug, :path_alias])
    |> Ash.read_one!(authorize?: false, tenant: org_id)
  end
end
