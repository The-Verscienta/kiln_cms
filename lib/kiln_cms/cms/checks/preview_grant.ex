defmodule KilnCMS.CMS.Checks.PreviewGrant do
  @moduledoc """
  Admits the one record a verified preview token names (#1887), so a headless
  front end can read a shared draft through the plain reads instead of holding
  an editor credential.

  The grant (`KilnCMS.CMS.PreviewGrant`) rides in the query's `:shared`
  context, put there by `KilnCMSWeb.Plugs.PreviewGrant` after the token was
  verified and pinned to the serving site. This check turns it into
  `id == ^grant.id`, and only when:

    * the read is the resource's **primary** read — the one JSON:API's
      `get`/`index` and every relationship load use. The published-only
      delivery actions (`:public_by_slug` and friends), search, semantic
      search and autocomplete are separate actions and stay as they were;
    * the query's tenant is the grant's site. The plug already refused a
      token from another site; this holds the same line for any read the
      context is carried into.

  A FilterCheck for the reason `Checks.InAudience` is one: a list read keeps
  the rows it matches rather than being authorized whole. No grant → `false`,
  which adds nothing to the SQL.
  """
  use Ash.Policy.FilterCheck

  alias KilnCMS.CMS.PreviewGrant

  @impl true
  def describe(_opts), do: "the record a verified preview token names"

  @impl true
  def filter(_actor, authorizer, _opts) do
    with %PreviewGrant{id: id, org_id: org_id} <- PreviewGrant.from_context(authorizer),
         %{action: %{type: :read, primary?: true}, subject: %{tenant: tenant}}
         when not is_nil(tenant) <- authorizer,
         # Not `nil`: `Accounts.org_id(nil)` is the default site, and a
         # tenant-less read is no read of the grant's site.
         ^org_id <- KilnCMS.Accounts.org_id(tenant) do
      expr(id == ^id)
    else
      _ -> false
    end
  end
end
