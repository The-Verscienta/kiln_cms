defmodule KilnCMS.I18n.Fallback do
  @moduledoc """
  Locale fallback chains: which locales to try, in order, when a document has
  no published variant in the one a reader asked for.

  Content is document-per-locale (`KilnCMS.I18n`), so a translation that does
  not exist yet is a *missing row*, and before this every surface answered it
  differently — the built-in site served the default locale, the headless API
  404'd, a menu came back `null`. A chain makes the answer a site decision:

      fr-CA → fr → en

  ## Where a chain comes from

  Two layers, most specific first — the `KilnCMS.Feeds` shape:

    1. the site's `KilnCMS.CMS.SiteLocaleSettings` row (`/editor/locales`);
    2. the operator default, `config :kiln_cms, :i18n, fallbacks: %{"fr-CA" => ["fr"]}`.

  A locale with **no entry** in either falls back to the site's default locale
  — what the built-in site has always done. A locale whose entry is `[]` does
  not fall back at all: an admin who would rather 404 than serve English on a
  French URL says so explicitly. A chain is taken **as written**: `fr-CA → fr`
  does not quietly continue on to the default locale, because a chain an admin
  wrote out is the whole of what they asked for.

  Every locale in a chain must be one the deployment runs (`KilnCMS.I18n.locales/0`);
  one that is not — a locale an operator has since removed — is dropped at read
  time rather than tried.

  ## Per request

  A caller can narrow the chain, never widen it past what it names:

    * `:site` — the site's chain (the default);
    * `:none` — the requested locale only (`?fallback=false`);
    * `{:only, locale}` — the requested locale, then that one
      (`?fallback_locale=fr`), whatever the site's chain says.

  ## Navigation takes only a chain someone wrote

  `KilnCMS.CMS.Menus` resolves with `implicit_default?: false`: a menu follows
  a configured chain (or a request's `fallback_locale`), but never the implicit
  last hop to the default locale. #466 decided that English navigation on a
  French page is worse than none, and nothing here reverses that for a site
  that has not said otherwise.

  ## When the site's row cannot be read

  `unavailable/0` answers **no fallback** — the requested locale only — for the
  one request, and it is the direction for a reason specific to this setting:
  delivery caches the *result* of a chain walk under the requested locale's
  key. A record found in the requested locale is correct under every chain, and
  a miss is never cached, so a degraded walk can leave nothing wrong behind. A
  walk along the operator default instead would cache an English document under
  a `fr-CA` key for the whole TTL on a site that chains `fr-CA → fr`.

  ## Field-level localization (#1327)

  Resolution here is by *locale*, not by row, on purpose: `chain/4` returns the
  ordered list of locales to try and knows nothing about documents. A
  field-level model (one row, `%{locale => value}` per localized field) resolves
  each field by walking the same list, so the chain a site configures now is
  the chain its localized fields will use.
  """

  alias KilnCMS.I18n

  defmodule Chains do
    @moduledoc """
    A site's resolved fallback configuration: the explicit chains (the
    `SiteLocaleSettings` row folded over the operator config), and whether the
    row could be read at all.

    A struct rather than a bare map for the reason `KilnCMS.Feeds.Policy` is
    one: `KilnCMS.I18n.Fallback.chain/4` takes an already-resolved value *or*
    an org, and a map would let a half-shaped value fall through to the org
    clause.
    """
    defstruct explicit: %{}, degraded?: false

    @type t :: %__MODULE__{explicit: %{String.t() => [String.t()]}, degraded?: boolean()}
  end

  @type mode :: :site | :none | {:only, String.t()}

  # Matches `KilnCMS.Feeds`/`KilnCMS.Branding`. The writing node busts precisely
  # (`KilnCMS.CMS.Changes.BustLocaleSettings`), so this bounds staleness only
  # for writes that change cannot see.
  @ttl :timer.minutes(5)

  @doc """
  The resolved chains for an org — an `%Organization{}`, a bare org id, or
  `nil` (the default org). Cached per org; never writes.
  """
  @spec chains(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: Chains.t()
  def chains(%KilnCMS.Accounts.Organization{id: id}) when is_binary(id), do: for_org_id(id)
  def chains(nil), do: for_org_id(KilnCMS.Accounts.default_org_id())
  def chains(org_id) when is_binary(org_id), do: for_org_id(org_id)
  def chains(_other), do: unavailable()

  defp for_org_id(org_id) do
    KilnCMS.OrgSettings.resolve(org_id,
      cache_key: KilnCMS.Cache.locale_fallbacks_key(org_id),
      ttl: @ttl,
      # `authorize?: false` bypass, as every delivery resolver's is: the row
      # is admin-only by policy and delivery has no actor. Safe because the
      # read is pinned to this one tenant and only the resolved chains — no
      # more than `GET /api/locales` publishes — ever leave this module.
      read: &KilnCMS.CMS.list_site_locale_settings(tenant: &1, authorize?: false),
      build: &for_row/1,
      fallback: &unavailable/0,
      label: "locale fallback settings"
    )
  end

  @doc """
  The chains for a `SiteLocaleSettings` row (or `nil` for a site without one),
  the operator config folded in underneath. Public so `/editor/locales` can
  show what the site does from the row it already holds.
  """
  @spec for_row(struct() | nil) :: Chains.t()
  def for_row(row) do
    explicit =
      case row && row.fallbacks do
        nil -> config_fallbacks()
        fallbacks -> fallbacks
      end

    %Chains{explicit: sanitize(explicit)}
  end

  @doc "The operator-level (config-only) chains, ignoring any site row."
  @spec defaults() :: Chains.t()
  def defaults, do: for_row(nil)

  @doc """
  The chains to use when the site's row **cannot be read**: none at all, for
  the one request. See the moduledoc for why this is not `defaults/0`.
  """
  @spec unavailable() :: Chains.t()
  def unavailable, do: %Chains{explicit: %{}, degraded?: true}

  @doc """
  The ordered locales to try for `locale` — always starting with `locale`
  itself, never repeating one, and only ever naming locales the deployment runs.

  `org_or_chains` is an org (anything `chains/1` takes) or an already-resolved
  `%Chains{}`, so a caller that walks several locales resolves the settings
  once.

  ## Options

    * `:implicit_default?` — whether a locale with no configured chain falls
      back to the default locale. Defaults to `true`; navigation passes `false`
      (see the moduledoc).
  """
  @spec chain(term(), String.t(), mode(), keyword()) :: [String.t()]
  def chain(org_or_chains, locale, mode \\ :site, opts \\ [])

  def chain(_org, locale, :none, _opts), do: [locale]

  def chain(_org, locale, {:only, fallback}, _opts),
    do: Enum.uniq([locale | Enum.filter([fallback], &I18n.supported?/1)])

  def chain(%Chains{degraded?: true}, locale, :site, _opts), do: [locale]

  def chain(%Chains{explicit: explicit}, locale, :site, opts) do
    tail =
      case Map.fetch(explicit, locale) do
        {:ok, configured} ->
          configured

        :error ->
          if Keyword.get(opts, :implicit_default?, true), do: [I18n.default_locale()], else: []
      end

    Enum.uniq([locale | Enum.filter(tail, &I18n.supported?/1)])
  end

  def chain(org, locale, :site, opts), do: chain(chains(org), locale, :site, opts)

  @doc """
  Every supported locale's chain for a site, *excluding* the locale itself —
  `%{"fr-CA" => ["fr", "en"], "en" => []}`. What `GET /api/locales` publishes,
  so a front end can see the rule rather than infer it from responses.
  """
  @spec effective(term()) :: %{String.t() => [String.t()]}
  def effective(org) do
    resolved = chains(org)
    Map.new(I18n.locales(), &{&1, tl(chain(resolved, &1))})
  end

  # Operator- and admin-written data both reach the anonymous delivery path, so
  # a malformed shape is dropped rather than raised on: a non-list value, a
  # non-string entry, a locale naming itself. Supported-ness is checked per
  # request (`chain/4`), not here, so a locale an operator adds later starts
  # working without a settings save.
  defp sanitize(fallbacks) when is_map(fallbacks) do
    for {locale, chain} <- fallbacks, is_binary(locale), is_list(chain), into: %{} do
      {locale, chain |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == locale)) |> Enum.uniq()}
    end
  end

  defp sanitize(_other), do: %{}

  defp config_fallbacks do
    opts = Application.get_env(:kiln_cms, :i18n, [])
    if Keyword.keyword?(opts), do: Keyword.get(opts, :fallbacks, %{}), else: %{}
  end
end
