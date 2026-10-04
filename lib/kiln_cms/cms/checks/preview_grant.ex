defmodule KilnCMS.CMS.Checks.PreviewGrant do
  @moduledoc """
  Admits the **one record** a verified preview token names
  (`KilnCMS.CMS.PreviewGrant`) to a plain read, whatever its state.

  The grant reaches a query through the Ash context the
  `KilnCMSWeb.Plugs.PreviewGrant` plug sets on headless reads (JSON:API, and
  the artifact read in `KilnCMSWeb.ArtifactController`). It is additive: the
  other read grants still apply, so a list read with a token returns what the
  caller could read anyway **plus** that one row — `id == grant.id` pinned to
  the grant's resource and site.

  Scope, deliberately narrow:

    * only the primary `:read` action — the JSON:API index/get routes and the
      relationship loads under them. `:published`, `:public_by_slug`,
      `search*`, `autocomplete*` and the semantic reads never surface a draft
      through a token;
    * only the resource the token's type resolves to, and only the token's own
      site (the tenant is compared too, on top of attribute multitenancy);
    * only reads — the check sits in the read policies alone, and the plug
      never builds a grant on a write request.

  It never consults the actor, so an anonymous caller and a `:viewer` key
  behave the same: the token is the grant.
  """
  use Ash.Policy.FilterCheck

  alias KilnCMS.CMS.PreviewGrant

  @impl true
  def describe(_opts), do: "the one record a verified preview token names"

  @impl true
  def filter(_actor, authorizer, _opts) do
    # `authorizer` is the `Ash.Policy.Authorizer` struct: `Map.get/2`, not Access.
    resource = Map.get(authorizer, :resource)
    action = Map.get(authorizer, :action)
    subject = Map.get(authorizer, :subject)

    with %{name: :read} <- action,
         %{context: context} <- subject,
         %PreviewGrant{resource: ^resource, id: id, org_id: org_id} <-
           PreviewGrant.from_context(context),
         true <- same_site?(subject, org_id) do
      expr(id == ^id and org_id == ^org_id)
    else
      _ -> false
    end
  end

  # A query with no tenant falls back to attribute multitenancy's own handling;
  # the filter's `org_id` pin still holds. A query for ANOTHER tenant never
  # matches — a token minted on one site is no key to another's rows.
  defp same_site?(%{tenant: nil}, _org_id), do: true

  defp same_site?(%{tenant: tenant}, org_id),
    do: KilnCMS.Accounts.org_id(tenant) == org_id

  defp same_site?(_subject, _org_id), do: true
end
