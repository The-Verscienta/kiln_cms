defmodule KilnCMS.CMS.Preparations.LocaleFallback do
  @moduledoc """
  Resolves `:public_by_slug`'s `locale` through the site's fallback chain
  (`KilnCMS.I18n.Fallback`) — one query for the whole chain, not one per hop.

  The read matches every published variant of the slug whose locale is *on*
  the chain and keeps the one earliest on it, so `fr-CA → fr → en` costs the
  same single indexed lookup a plain `fr-CA` read did. Every surface built on
  the action inherits it without code of its own: the GraphQL `*BySlug`
  queries, the JSON:API `/by-slug/:slug` routes, and the delivery controllers
  that call it through `KilnCMS.CMS.ContentTypes.get_published_by_slug/4`.

  The served locale is the record's own `locale` — callers report that, never
  the one they asked for.

  ## Arguments it reads

    * `locale` — must be a locale the deployment runs. Anything else is an
      `InvalidArgument`, not a silent substitution of the default: `fr_CA`
      answering with the English document is the bug this replaced.
    * `fallback` — `false` reads the requested locale only.
    * `fallback_locale` — replaces the site's chain with this one locale. Held
      to the same supported-locale rule as `locale`.

  ## Only readable variants take part

  The chain is ANDed with the action's own filter, so a variant this caller
  may not read — gated, passphrase-locked, unpublished — is treated exactly as
  a missing one and the walk moves on. That matches what the built-in site did
  before chains existed (a locked French page served the English one), and it
  is the only answer that does not tell an anonymous caller which translations
  exist behind a lock.

  ## Why the chain is resolved in `before_action`

  Preparations run when the query is *built*; the tenant a GraphQL or JSON:API
  request carries is not guaranteed to be on the query yet at that point, and
  resolving the chain against the wrong org would read another site's
  settings. The argument checks are pure, so they stay at build time and fail
  early.
  """
  use Ash.Resource.Preparation

  require Ash.Query
  require Ash.Sort

  alias Ash.Error.Query.InvalidArgument
  alias KilnCMS.I18n
  alias KilnCMS.I18n.Fallback

  @impl true
  def prepare(query, _opts, _context) do
    locale = Ash.Query.get_argument(query, :locale)
    fallback_locale = Ash.Query.get_argument(query, :fallback_locale)

    cond do
      not supported?(locale) ->
        unsupported(query, :locale, locale)

      not (is_nil(fallback_locale) or supported?(fallback_locale)) ->
        unsupported(query, :fallback_locale, fallback_locale)

      true ->
        mode = mode(Ash.Query.get_argument(query, :fallback), fallback_locale)
        Ash.Query.before_action(query, &apply_chain(&1, locale, mode))
    end
  end

  defp apply_chain(query, requested, mode) do
    # `locale` inside the filter and sort below is the record's attribute (an
    # expression reference), not a variable — hence `requested` here.
    case Fallback.chain(org_id(query.tenant), requested, mode) do
      [only] ->
        Ash.Query.filter(query, locale == ^only)

      chain ->
        query
        |> Ash.Query.filter(locale in ^chain)
        |> Ash.Query.sort(
          [
            {Ash.Sort.expr_sort(
               fragment("array_position(?::text[], ?)", ^chain, locale),
               :integer
             ), :asc}
          ],
          prepend?: true
        )
        |> Ash.Query.limit(1)
    end
  end

  @doc false
  # `fallback: false` wins over a `fallback_locale`: a caller that asked for no
  # fallback and named one has asked for two things, and the narrower is the
  # one that cannot surprise them.
  @spec mode(boolean() | nil, String.t() | nil) :: Fallback.mode()
  def mode(false, _fallback_locale), do: :none
  def mode(_fallback, nil), do: :site
  def mode(_fallback, fallback_locale), do: {:only, fallback_locale}

  defp supported?(locale), do: is_binary(locale) and I18n.supported?(locale)

  defp unsupported(query, field, value) do
    Ash.Query.add_error(
      query,
      InvalidArgument.exception(
        field: field,
        message: "#{inspect(value)} is not a locale this site serves (see GET /api/locales)"
      )
    )
  end

  defp org_id(%{id: id}) when is_binary(id), do: id
  defp org_id(id) when is_binary(id), do: id
  defp org_id(_none), do: KilnCMS.Accounts.default_org_id()
end
