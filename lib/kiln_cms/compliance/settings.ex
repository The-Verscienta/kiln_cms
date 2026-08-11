defmodule KilnCMS.Compliance.Settings do
  @moduledoc """
  One site's resolved claim-checking settings (#857) — the answer every part of
  the feature is judged against, with the per-org row and the operator config
  already folded together.

  Two layers, most specific first:

    1. the site's `KilnCMS.CMS.SiteCompliance` row, edited at
       `/editor/compliance`,
    2. `config :kiln_cms, KilnCMS.Compliance` — the deployment-wide operator
       default, which is what a single-tenant install uses and what every
       install used before this existed.

  A site with no row resolves to layer 2 exactly, so nothing changes for an
  install that never opens the page.

  ## Why the row is not just "more config"

  Claim checking was config-only, which is the wrong grain on a shared install
  (#336): a claims vocabulary is a statement about one publication's voice and
  jurisdiction, and `require_at_publish` is a hard refusal. One tenant deciding
  that "cures" cannot ship applied that to every other site on the instance,
  with no override — and the tenant that wanted the panel *off* could not turn
  it off either.

  ## A struct, not a map

  Every consumer takes a resolved `t:t/0` and nothing else: the advisory checks
  read it out of `Kiln.Advisory.Context` facts, the publish gate resolves it
  from the changeset's tenant, the editor holds it in an assign. A map would
  let a half-shaped one — or a `nil`, or an org id — fall through into a clause
  that resolved the *default* org's settings, which is precisely the
  cross-tenant answer this module exists to remove.
  """

  alias Kiln.Advisory.Context
  alias KilnCMS.Accounts
  alias KilnCMS.CMS.SiteCompliance
  alias KilnCMS.Compliance

  require Logger

  @typedoc """
  `rules` is already merged and ordered; `shipped_pack?` records whether it is
  *exactly* the shipped English pack, which is what decides whether a
  non-English document can be judged at all.
  """
  @type t :: %__MODULE__{
          enabled?: boolean(),
          require_at_publish?: boolean(),
          disclaimer: String.t() | nil,
          rules: [Compliance.rule()],
          shipped_pack?: boolean()
        }

  defstruct enabled?: false,
            require_at_publish?: false,
            disclaimer: nil,
            rules: [],
            shipped_pack?: true

  # The rule code a site's own phrases become. One fixed code rather than one
  # per row or per phrase: a code is an atom the web layer translates
  # (`KilnCMSWeb.ComplianceComponents`), and minting atoms from column values
  # turns a settings table into an unbounded atom table.
  @site_rule_code :site_claim

  # Matches `KilnCMS.Branding`'s. The cache is in-BEAM only (D2), so this also
  # bounds staleness on other nodes after a save; the writing node is busted
  # precisely by `KilnCMS.CMS.Changes.BustCompliance`.
  @ttl :timer.minutes(5)

  @doc "The rule code a site's own phrase list matches under."
  @spec site_rule_code() :: atom()
  def site_rule_code, do: @site_rule_code

  @doc """
  The resolved settings for an org — an `%Organization{}`, a bare org id, or
  `nil` (the default org).

  Cached per org for #{div(@ttl, 60_000)} minutes. The editor resolves this on
  every form change, so the cost that matters is the ETS read, not the query;
  and the cached value is the **resolved struct**, never the row, because most
  sites have no row and `KilnCMS.Cache.fetch/3` deliberately never caches a
  `nil` — caching the lookup itself would mean a database hit forever.
  """
  @spec for_org(Accounts.Organization.t() | Ash.UUID.t() | nil) :: t()
  def for_org(%Accounts.Organization{id: id}) when is_binary(id), do: for_org_id(id)
  def for_org(nil), do: for_org_id(Accounts.default_org_id())
  def for_org(org_id) when is_binary(org_id), do: for_org_id(org_id)

  # Anything that is not an org degrades rather than raising, as
  # `KilnCMS.Feeds.policy/1` does. Spelling the accepted shapes out rather than
  # deferring to `Accounts.org_id/1` keeps a stray socket or changeset from
  # being read as an org id and answering with the *default* org's settings.
  def for_org(_other), do: unavailable()

  @doc """
  As `for_org/1`, but reading the row directly instead of through the cache.

  For a caller **inside a write transaction** — the publish gate. `Cachex`
  runs a cache miss's fallback on a courier process, so a cached resolve from
  inside a transaction checks out a *second* pool connection while the first is
  still held. That is a second connection per publish at best, and under a
  saturated pool it is publishes waiting on each other: the transaction cannot
  finish until it gets a connection that the transaction itself is helping to
  hold.

  Affordable precisely because of who calls it: a publish is rare and already
  writing, so one indexed single-row read is nothing. The editor's per-keystroke
  path is the one that needs the cache, and it is not in a transaction.
  """
  @spec for_org_uncached(Accounts.Organization.t() | Ash.UUID.t() | nil) :: t()
  def for_org_uncached(%Accounts.Organization{id: id}) when is_binary(id),
    do: resolve(id) || unavailable()

  def for_org_uncached(nil), do: for_org_uncached(Accounts.default_org_id())

  def for_org_uncached(org_id) when is_binary(org_id), do: resolve(org_id) || unavailable()

  def for_org_uncached(_other), do: unavailable()

  defp for_org_id(org_id) do
    # `resolve/1` returns nil only on an infrastructure failure, which the cache
    # then declines to store — so a transient error degrades for one call rather
    # than for the whole TTL. It degrades to `unavailable/0`, not to the
    # operator config: see that function.
    KilnCMS.Cache.fetch(KilnCMS.Cache.compliance_key(org_id), @ttl, fn -> resolve(org_id) end) ||
      unavailable()
  end

  defp resolve(org_id) do
    SiteCompliance
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: org_id)
    |> case do
      {:ok, row} ->
        for_row(row)

      {:error, reason} ->
        Logger.warning(
          "compliance: could not read settings for #{org_id}, " <>
            "falling back to the operator config with the publish gate off: #{inspect(reason)}"
        )

        nil
    end
  end

  @doc """
  The operator-level (config-only) settings, ignoring any per-site row.

  What a site with no row gets, and what the settings page shows as the
  starting point it would inherit.
  """
  @spec defaults() :: t()
  def defaults, do: for_row(nil)

  @doc """
  The settings to use when a site's row **cannot be read** — a rolling deploy
  before the table exists, a pool timeout under load.

  The operator config for the advisory axes, and the publish gate **off**.

  Not `defaults/0` wholesale, and the difference is the one axis that can turn
  a transient read error into a site that cannot publish at all. A tenant that
  saved `require_at_publish: false` against a deployment configured `true`
  would, on any read blip, start refusing every publish — quoting phrases from
  a vocabulary that tenant may have switched off, since the site's own rules
  are exactly what could not be read. Refusing on rules nobody could confirm is
  not a stricter gate, it is a wrong one.

  The advisory axes keep the operator default because failing them closed means
  "no panel", and an author who sees no panel is told nothing at all. A panel
  that appears for one call is noise; a publish refused for the duration of a
  fault is an outage.
  """
  @spec unavailable() :: t()
  def unavailable, do: %__MODULE__{defaults() | require_at_publish?: false}

  @doc """
  Resolve settings from a `SiteCompliance` row already in hand (or `nil`).

  The settings page uses this so the form shows what the site actually does
  today — its own row over the operator config — without a second read that
  would always miss the cache the save just busted.
  """
  @spec for_row(SiteCompliance.t() | nil) :: t()
  def for_row(row) do
    rules = rules(row)

    %__MODULE__{
      enabled?: enabled?(row),
      # Read *through* `enabled?`, exactly as the config pair always was: with
      # checking off there is nothing to have matched, so a gate on its own is
      # inert rather than a refusal with no vocabulary behind it.
      require_at_publish?: enabled?(row) and require_at_publish?(row),
      disclaimer: disclaimer(row),
      rules: rules,
      shipped_pack?: rules == Compliance.default_rules()
    }
  end

  @doc """
  Whether `context`'s locale is one these rules can judge.

  The shipped pack is English phrases, so a French document under it reports
  `:n_a` rather than passing — a document nobody could check is not a document
  that is clean. Any *other* rule set is assumed to fit the content it was
  written for, whether it came from config or from the site's own phrase list.
  """
  @spec judgeable?(t(), Context.t()) :: boolean()
  def judgeable?(%__MODULE__{} = settings, %Context{} = context),
    do: not settings.shipped_pack? or Context.english?(context)

  @doc """
  As `judgeable?/2`, for a caller holding a locale string rather than a context.

  Exists so the publish gate applies the *same* test as the panel. A gate that
  refused a French page quoting an English phrase the panel never showed is the
  one divergence this feature must not have.
  """
  @spec judgeable_locale?(t(), String.t()) :: boolean()
  def judgeable_locale?(%__MODULE__{} = settings, locale) when is_binary(locale),
    do: not settings.shipped_pack? or Compliance.english_locale?(locale)

  # --- the two layers ---------------------------------------------------

  defp enabled?(%SiteCompliance{enabled: enabled}), do: enabled
  defp enabled?(nil), do: config(:enabled, false) == true

  defp require_at_publish?(%SiteCompliance{require_at_publish: gate}), do: gate
  defp require_at_publish?(nil), do: config(:require_at_publish, false) == true

  # Blank falls through to the operator's, the `KilnCMS.Branding` rule: a text
  # box has no third state, and a required disclaimer dropped by an admin
  # tabbing past an empty field is a compliance requirement lost silently.
  defp disclaimer(row) do
    presence(row && row.disclaimer) || presence(config(:disclaimer, nil))
  end

  # The deployment's rules (unless the site opted out of them) plus the site's
  # own phrases as one rule. Order matters only for display; the site's rule
  # goes last so a panel reads "the shipped concerns, then ours".
  defp rules(row) do
    shared = if shared_rules?(row), do: config_rules(), else: []

    case site_rule(row) do
      nil -> shared
      rule -> shared ++ [rule]
    end
  end

  defp shared_rules?(%SiteCompliance{use_shared_rules: use?}), do: use?
  defp shared_rules?(nil), do: true

  defp site_rule(%SiteCompliance{phrases: phrases, phrase_severity: severity})
       when is_list(phrases) do
    case Enum.filter(phrases, &(is_binary(&1) and String.trim(&1) != "")) do
      [] -> nil
      kept -> %{code: @site_rule_code, severity: severity, phrases: kept}
    end
  end

  defp site_rule(_row), do: nil

  # `:default` resolves to the shipped pack; a configured list is filtered by
  # `Compliance.rules_from/1`, which drops junk entries rather than letting a
  # malformed map raise inside a check (where the registry would swallow it into
  # a silently absent advisory).
  defp config_rules, do: Compliance.rules_from(config(:rules, :default))

  defp config(key, default), do: Keyword.get(config(), key, default)

  defp config, do: Application.get_env(:kiln_cms, Compliance, [])

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_other), do: nil
end
