defmodule KilnCMS.BotBudgets do
  @moduledoc """
  How many `:delivery` requests per window one address may make, by the class
  of client its user agent claims to be (#2243, `KilnCMS.BotClass`).

  ## One counter, a ceiling per class

  Every class spends the **same** per-address counter (`"delivery:<ip>"` in
  `KilnCMSWeb.RateLimit`); only the point at which a request is refused
  differs. A browser's ceiling is the `:delivery` limit itself, so browsers are
  throttled exactly as before. Switching user agents gains nothing: the counter
  never resets, so an address can never get past the highest single class
  ceiling.

  Each other class's ceiling is a percentage of the `:delivery` limit:

      ceiling = max(1, div(delivery_limit * percent, 100))

  so raising `:delivery` (a benchmark does) raises every class with it.

  ## Who sets the percentage

    * **Built-in defaults**: search engines 200% (#2587), AI crawlers 100%,
      declared bots 50%, an empty user agent 20%. Browsers are always 100%.
      The search-engine 200% is spent only on addresses
      `KilnCMS.CrawlerVerification` has proven to be the engine's: a claim not
      proven either way is held to the browser limit
      (`unverified_search_limit/0`), and one proven false is charged as
      `:empty`. With verification off nothing is proven, so the search-engine
      default is 100% instead (what it was before #2587): a higher default
      would loosen the flood ceiling for anyone typing "Googlebot". An operator
      value is used as given either way.
    * **The operator** (`KILN_BOT_BUDGET_*_PERCENT`, written to
      `config :kiln_cms, KilnCMSWeb.RateLimit, delivery_classes: %{...}`)
      replaces a default, 1-1000.
    * **A site** (`KilnCMS.CMS.SiteBotBudgets`) may lower a class below the
      operator's value, never raise it above: the effective value is
      `min(site, operator)`. The write is refused above the operator's value
      (`KilnCMS.CMS.Validations.BotBudgetCeiling`) and a stored value is
      clamped here, the `KilnCMS.Forms.EmbedCeiling` precedent. Each class is
      independent: a site that sets one inherits the rest.

  No value is 0 or unlimited. Refusing a class is the IP block list's job
  (#2242), or a robots.txt served in front of Kiln; an unlimited class would be
  a bypass for anyone who spoofs it.

  ## Reading the site's row

  As `KilnCMS.OrgSettings.system(:bot_budgets)`, through
  `KilnCMS.OrgSettings.resolve_uncached/2` with `authorize_with: :error`,
  cached per org for five minutes and busted on every write. A row that cannot
  be read (a refusal, a missing table mid-deploy, a pool timeout) is logged and
  answered with the operator's values: the operator owns capacity, so that is
  never wider than what they allowed. That answer is remembered for 20 seconds,
  so an outage costs one read per org per interval rather than one per
  request. Browsers never look the row up.
  """

  alias KilnCMS.BotClass

  @type class :: BotClass.t()
  @type source :: :site | :operator | :default

  @ttl :timer.minutes(5)

  # How long "the row could not be read" is remembered (see `site_values/1`).
  @unreadable_ttl :timer.seconds(20)

  @min_percent 1
  @max_percent 1000

  @defaults %{search_engine: 200, ai_crawler: 100, declared_bot: 50, empty: 20}

  # The search-engine default while crawler verification is off (#2587): no
  # claim can be proven, so the default stays at the browser limit.
  @unchecked_search_default 100

  # The classes a percentage can be set for, and the `SiteBotBudgets` column of
  # each. `:browser` is absent: its ceiling is the `:delivery` limit.
  @fields [
    search_engine: :search_engine_percent,
    ai_crawler: :ai_crawler_percent,
    declared_bot: :declared_bot_percent,
    empty: :empty_percent
  ]

  @configurable Keyword.keys(@fields)

  @doc "The classes a percentage can be set for, in display order."
  @spec configurable() :: [class()]
  def configurable, do: @configurable

  @doc "Each configurable class with its `SiteBotBudgets` column."
  @spec fields() :: [{class(), atom()}]
  def fields, do: @fields

  @doc """
  The built-in percentage of each configurable class, with crawler verification
  on. With it off, the search-engine default is 100 (see `operator_percent/1`).
  """
  @spec defaults() :: %{class() => pos_integer()}
  def defaults, do: @defaults

  @doc "The range a percentage may take, operator's or site's."
  @spec bounds() :: {pos_integer(), pos_integer()}
  def bounds, do: {@min_percent, @max_percent}

  @doc """
  The operator's percentage for `class`: the `delivery_classes` config value
  when it is an integer in range, else the built-in default. 100 for a browser.

  The search-engine default is 200 while `KilnCMS.CrawlerVerification` is on and
  100 while it is off, so an unset variable never lets an unchecked claim spend
  more than a browser (#2587).
  """
  @spec operator_percent(class()) :: pos_integer()
  def operator_percent(:browser), do: 100

  def operator_percent(class) when class in @configurable do
    case operator_value(class) do
      nil -> default_percent(class)
      value -> value
    end
  end

  defp default_percent(:search_engine) do
    if KilnCMS.CrawlerVerification.enabled?(),
      do: Map.fetch!(@defaults, :search_engine),
      else: @unchecked_search_default
  end

  defp default_percent(class), do: Map.fetch!(@defaults, class)

  @doc """
  The effective percentage for `class` on `org` (an `Organization`, an org id,
  or `nil` for none): `min(site, operator)`, or the operator's value when the
  site sets none.
  """
  @spec percent(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil, class()) ::
          pos_integer()
  def percent(_org, :browser), do: 100

  def percent(org, class) when class in @configurable do
    operator = operator_percent(class)

    case site_values(org) |> Map.get(class) do
      site when is_integer(site) -> min(site, operator)
      _inherit -> operator
    end
  end

  @doc """
  The ceiling for `class` on `org`, in requests per `:delivery` window: the
  effective percentage of the `:delivery` limit, at least 1.
  """
  @spec limit(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil, class()) :: pos_integer()
  def limit(org, class), do: ceiling(delivery_limit(), percent(org, class))

  @doc """
  The operator's ceiling for `class`, in requests per `:delivery` window. No
  database read: the limiter charges against this first, so a request it
  refuses never reaches the site's row.
  """
  @spec operator_limit(class()) :: pos_integer()
  def operator_limit(class), do: ceiling(delivery_limit(), operator_percent(class))

  @doc """
  The operator's search-engine ceiling for a claim `KilnCMS.CrawlerVerification`
  has neither proven nor disproven (#2254): `operator_limit(:search_engine)`,
  but never above the `:delivery` limit. A search-engine percentage above 100
  is spent only on addresses proven to be the engine's; below 100 this is the
  same as `operator_limit(:search_engine)`. No database read.
  """
  @spec unverified_search_limit() :: pos_integer()
  def unverified_search_limit, do: min(operator_limit(:search_engine), delivery_limit())

  @doc "`max(1, div(delivery_limit * percent, 100))`."
  @spec ceiling(pos_integer(), pos_integer()) :: pos_integer()
  def ceiling(delivery_limit, percent)
      when is_integer(delivery_limit) and delivery_limit > 0 and is_integer(percent) and
             percent > 0,
      do: max(1, div(delivery_limit * percent, 100))

  @doc "The `:delivery` bucket's limit, which is also the browser ceiling."
  @spec delivery_limit() :: pos_integer()
  def delivery_limit do
    {limit, _scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), :delivery)
    limit
  end

  @doc """
  What `/editor/bot-budgets` shows for each configurable class on `org`:

    * `:percent` and `:limit`: the effective values;
    * `:source`: `:site` when the site's own value applies, `:operator` when
      the operator's does (because the site sets none, or because a stored site
      value is above it and was clamped), `:default` when neither is set;
    * `:site_percent`: what the site stored, or `nil`;
    * `:operator_percent` and `:operator_source` (`:operator` or `:default`):
      the most this site may set;
    * `:clamped?`: the site stored more than the operator now allows.

  Reads the row through the same cache as delivery.
  """
  @spec effective(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: %{
          class() => map()
        }
  def effective(org) do
    site = site_values(org)
    delivery_limit = delivery_limit()

    Map.new(@configurable, fn class ->
      operator = operator_percent(class)
      operator_source = if operator_value(class), do: :operator, else: :default
      site_percent = Map.get(site, class)

      {percent, source} =
        if is_integer(site_percent) and site_percent <= operator,
          do: {site_percent, :site},
          else: {operator, operator_source}

      {class,
       %{
         percent: percent,
         limit: ceiling(delivery_limit, percent),
         source: source,
         site_percent: site_percent,
         operator_percent: operator,
         operator_source: operator_source,
         clamped?: is_integer(site_percent) and site_percent > operator
       }}
    end)
  end

  # `nil` when the operator set nothing usable for `class`. An integer outside
  # 1-1000 (an overlay's own config; runtime.exs refuses one already) is
  # ignored rather than trusted.
  defp operator_value(class) do
    case Map.get(operator_config(), class) do
      value when is_integer(value) and value >= @min_percent and value <= @max_percent -> value
      _unset_or_invalid -> nil
    end
  end

  defp operator_config do
    case Application.get_env(:kiln_cms, KilnCMSWeb.RateLimit, [])
         |> Keyword.get(:delivery_classes) do
      %{} = classes -> classes
      _unset -> %{}
    end
  end

  # The site's stored values, `%{class => integer | nil}`, or `%{}` when the
  # site has no row, there is no org, or the row could not be read.
  #
  # Two keys. The inner one holds the values for `@ttl`, and never holds a
  # failed read (`OrgSettings.resolve_uncached/2` answers `nil`, which the cache
  # declines to store). The outer one holds whichever answer came back, a
  # failure included, for `@unreadable_ttl`: during an outage every allowed
  # non-browser request would otherwise retry the read, so it costs one read
  # per org per interval instead. A save busts both.
  defp site_values(nil), do: %{}

  defp site_values(org) do
    org_id = KilnCMS.Accounts.org_id(org)
    actor = KilnCMS.OrgSettings.system(:bot_budgets)

    opts = [
      read:
        &KilnCMS.CMS.list_site_bot_budgets(
          tenant: &1,
          actor: actor,
          authorize_with: :error
        ),
      build: &build/1,
      label: "bot budgets"
    ]

    recent =
      KilnCMS.Cache.fetch(KilnCMS.Cache.bot_budgets_recent_key(org_id), @unreadable_ttl, fn ->
        KilnCMS.Cache.fetch(KilnCMS.Cache.bot_budgets_key(org_id), @ttl, fn ->
          KilnCMS.OrgSettings.resolve_uncached(org_id, opts)
        end) || :unreadable
      end)

    case recent do
      %{} = values -> values
      # Unreadable: the operator's values.
      :unreadable -> %{}
    end
  end

  defp build(nil), do: %{}
  defp build(row), do: Map.new(@fields, fn {class, field} -> {class, Map.get(row, field)} end)
end
