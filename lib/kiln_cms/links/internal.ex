defmodule KilnCMS.Links.Internal do
  @moduledoc """
  Resolves the same-origin links a document's body contains (#474).

  An author types `/blog/the-thing` into a link. Later the thing is renamed,
  unpublished or deleted, and nothing tells them — the link keeps rendering and
  quietly 404s for every reader. This answers, for a path, what a *visitor*
  would get if they clicked it.

  ## "I could not resolve it" is not "it is broken"

  This is the constraint the whole module is shaped by, and getting it wrong is
  what makes a link checker useless.

  The router serves far more than content: `/`, `/blog`, `/search`,
  `/developers`, `/feed.xml`, `/uploads/…`, and every plugin's public routes.
  Enumerating them here would be a second copy of the router, wrong the day
  either changes. So the resolver reports `:unknown` for any path outside a
  namespace it *owns*, and `:unknown` is never shown to anyone.

  Guessing the other way is worse than not checking at all: a single `:error`
  grades a document Poor (`KilnCMS.Seo.Analyzer`), so one "read more on our
  blog" link would mark every page on the site as failing, and authors would
  learn within a day to ignore the panel.

  What it *does* own, and will therefore call missing:

    * `/<content-prefix>/<slug>` — the prefix names a content type, so an
      absent slug under it is genuinely a 404.
    * any path a `path_alias` or a redirect matches — a positive hit needs no
      guessing.

  Everything else is `:unknown`.

  ## It follows delivery's order, and its locale rules

  `KilnCMSWeb.ContentController` resolves a miss as: multi-segment path alias,
  then the redirect table, then a paywall teaser, then 404 — with a flat
  `/<prefix>/<slug>` served by the ordinary route ahead of all that, and
  `Plugs.SetLocale` stripping a leading supported-locale segment before any of
  it. Delivery also retries in the default locale when a localized lookup
  misses. All of that is mirrored here, because a checker with its own idea of
  what resolves reports links that work and misses links that don't.

  The one deliberate difference is *state*. Delivery sees published content
  only, so an unpublished target is a 404 to it and indistinguishable from a
  deleted one. To an editor those are opposite problems — "publish the draft"
  versus "this link is wrong" — so this looks in every state and says which.

  ## A redirect is not a broken link

  A published rename leaves a `KilnCMS.CMS.Redirect` behind and delivery serves
  a 301. Flagging that reports a working feature as a fault.

  ## Failure is `:unknown`, never `:missing`

  A query that errors says nothing about the link. Reporting it as broken would
  turn a transient database blip into a panel full of false errors, so every
  error path lands on `:unknown`.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Redirects
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.I18n

  @typedoc """
  What a visitor clicking this path would get.

    * `:published` — the page they expected.
    * `{:unpublished, state}` — a real document, not currently served. `state`
      is `:draft`, `:in_review` or `:archived`.
    * `:redirected` — a 301 to somewhere that works.
    * `:missing` — a 404, in a namespace this module owns. The only negative
      verdict it is ever confident enough to report.
    * `:unknown` — not something this module can judge: a router route, a
      plugin path, a deep path with no alias, or a query that failed.
    * `:external` — not a same-origin path at all.
  """
  @type resolution ::
          :published
          | {:unpublished, atom()}
          | :redirected
          | :missing
          | :unknown
          | :external

  @doc """
  Resolve every path in `paths` as `%{path => resolution}`.

  Keyed by the paths the caller passed — `/x`, `/x#a` and `/x?b=1` cost one
  lookup between them, but each is a key, because those are what the caller
  holds.

  `locale` and `org_id` scope the lookup as a request would. **`org_id` is a
  uuid**, not an `Organization` — it reaches a Cachex key, where a struct raises
  on `String.Chars`.
  """
  @spec resolve_all([String.t()], String.t(), Ash.UUID.t()) :: %{String.t() => resolution()}
  def resolve_all(paths, locale, org_id) do
    paths = paths |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()

    lookups =
      paths
      |> Enum.filter(&internal?/1)
      |> Enum.map(&normalize/1)
      |> Enum.uniq()
      |> Map.new(&{&1, lookup_path(&1, locale, org_id)})

    Map.new(paths, fn path ->
      {path, if(internal?(path), do: Map.fetch!(lookups, normalize(path)), else: :external)}
    end)
  end

  @doc "Resolve one path. See `t:resolution/0`."
  @spec resolve(String.t(), String.t(), Ash.UUID.t()) :: resolution()
  def resolve(path, locale, org_id) when is_binary(path) do
    # Classified BEFORE normalizing: normalization drops the query and fragment,
    # so a bare `#anchor` would otherwise become `/` and be resolved against the
    # home page. A same-page anchor is not a link to another document.
    if internal?(path),
      do: path |> normalize() |> lookup_path(locale, org_id),
      else: :external
  end

  def resolve(_path, _locale, _org_id), do: :external

  @doc """
  Whether `resolution` is something to tell the author about.

  The single definition of "a problem" — the advisory check asks this rather
  than re-deciding, so the two cannot drift on whether a redirect counts.
  """
  @spec problem?(resolution()) :: boolean()
  def problem?(:missing), do: true
  def problem?({:unpublished, _state}), do: true
  def problem?(_resolution), do: false

  defp lookup_path(path, locale, org_id) do
    # `Plugs.SetLocale` strips a leading supported-locale segment before the
    # router sees the path, and every hreflang link and locale switcher emits
    # exactly that shape — so an author copying a live URL gets one. Without
    # this, `/fr/blog/x` splits into three segments and resolves as nothing.
    {path, locale} = pop_locale(path, locale)

    case owned_namespace(path, org_id) do
      {:content, ct, slug} ->
        lookup(ct, slug, locale, org_id) || alias_or_redirect(path, locale, org_id) || :missing

      :not_ours ->
        alias_or_redirect(path, locale, org_id) || :unknown
    end
  end

  # Only a positive hit counts outside a namespace we own — the router serves
  # plenty this module knows nothing about.
  defp alias_or_redirect(path, locale, org_id) do
    by_alias(path, locale, org_id) || redirect(path, locale, org_id)
  end

  # `/<prefix>/<slug>` where the prefix names a content type is ours, and that
  # lookup is the whole test: a router-owned segment (`/search/x`, `/editor/x`)
  # simply is not a content type, so it falls out as `:not_ours` without a
  # separate reserved-list check. (Filtering on `reserved_path_segments/0` would
  # be actively wrong — `"blog"` is *in* it, reserved against dynamic types
  # precisely because the compiled `post` type already owns it.)
  #
  # A single segment is deliberately NOT ours even when a root-served type
  # exists: `/about` is as likely to be a plugin route or a static page, and a
  # wrong `:missing` costs far more than a missed one.
  defp owned_namespace(path, org_id) do
    with [prefix, slug] <- String.split(path, "/", trim: true),
         ct when not is_nil(ct) <- ContentTypes.get_by_path(prefix, org_id) do
      {:content, ct, slug}
    else
      _other -> :not_ours
    end
  end

  defp pop_locale(path, locale) do
    case String.split(path, "/", trim: true) do
      [maybe_locale | rest] when rest != [] ->
        if I18n.supported?(maybe_locale),
          do: {"/" <> Enum.join(rest, "/"), maybe_locale},
          else: {path, locale}

      _other ->
        {path, locale}
    end
  end

  # The query and fragment dropped: `/a/b?x=1#c` and `/a/b` are the same
  # document, and an anchor into a page that exists is not a broken link.
  defp normalize(path) do
    path
    |> String.trim()
    |> String.split(["?", "#"], parts: 2)
    |> hd()
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  # A protocol-relative `//host/x` is NOT internal — it is an absolute URL
  # wearing a leading slash, and treating it as a path is how a checker starts
  # resolving other people's hostnames against its own content.
  defp internal?(path) when is_binary(path) do
    case String.trim(path) do
      "//" <> _rest -> false
      "/" <> _rest -> true
      _other -> false
    end
  end

  defp internal?(_path), do: false

  # Every state, so a draft target reads as "not published yet" rather than
  # "gone". Retried in the default locale exactly as delivery retries
  # (`ContentController.localized/2`) — without it, a partially translated site
  # reports every link in a translated document as broken.
  defp lookup(ct, slug, locale, org_id) do
    do_lookup(ct, slug, locale, org_id) || default_locale_retry(ct, slug, locale, org_id)
  end

  defp default_locale_retry(ct, slug, locale, org_id) do
    default = I18n.default_locale()
    if locale == default, do: nil, else: do_lookup(ct, slug, default, org_id)
  end

  defp do_lookup(ct, slug, locale, org_id) do
    case filter_for(Slugs.storage_resource(ct), ct, slug, locale) do
      nil -> nil
      query -> query |> Ash.Query.select([:state]) |> read_state(org_id)
    end
  end

  # Every dynamic type shares one storage table (`KilnCMS.CMS.Entry`), so a slug
  # alone is ambiguous — an entry is identified by its `type_definition_id`, and
  # without it `/events/x` happily resolves against a `/recipes/x`.
  defp filter_for(resource, %{source: :dynamic, definition: %{id: definition_id}}, slug, locale) do
    Ash.Query.filter(
      resource,
      slug == ^slug and locale == ^locale and type_definition_id == ^definition_id
    )
  end

  # A dynamic descriptor with no loaded definition cannot be disambiguated, and
  # guessing would resolve one type's slug against another's.
  defp filter_for(_resource, %{source: :dynamic}, _slug, _locale), do: nil

  defp filter_for(resource, _ct, slug, locale) do
    Ash.Query.filter(resource, slug == ^slug and locale == ^locale)
  end

  # The multi-segment alias fallback (#485), in every state and with the same
  # default-locale retry.
  defp by_alias(path, locale, org_id) do
    default = I18n.default_locale()

    Enum.find_value(alias_resources(), fn resource ->
      alias_state(resource, path, locale, org_id) ||
        if(locale != default, do: alias_state(resource, path, default, org_id))
    end)
  end

  defp alias_state(resource, path, locale, org_id) do
    resource
    |> Ash.Query.filter(path_alias == ^path and locale == ^locale)
    |> Ash.Query.select([:state])
    |> read_state(org_id)
  end

  # An error says nothing about the link, so it must not become a verdict — a
  # transient database blip would otherwise fill an author's panel with errors
  # about links that are perfectly fine. Same for a multi-match.
  defp read_state(query, org_id) do
    case Ash.read_one(query, authorize?: false, tenant: org_id) do
      {:ok, %{state: :published}} -> :published
      {:ok, %{state: state}} -> {:unpublished, state}
      {:ok, nil} -> nil
      {:error, reason} -> log_and_skip(reason)
    end
  end

  defp log_and_skip(reason) do
    Logger.debug("link check: lookup failed, treating as unknown: #{inspect(reason)}")
    :unknown
  end

  defp alias_resources do
    ContentTypes.all()
    |> Enum.map(&Slugs.storage_resource/1)
    |> Enum.concat([KilnCMS.CMS.Entry])
    |> Enum.uniq()
  end

  # `Redirects.resolve/3` refuses to point at an unpublished target, so a
  # redirect that resolves is one a visitor actually follows. It uses bang
  # reads, so a database error would otherwise escape and take the caller down.
  defp redirect(path, locale, org_id) do
    if Redirects.resolve(path, locale, org_id), do: :redirected
  rescue
    exception -> log_and_skip(exception)
  end
end
