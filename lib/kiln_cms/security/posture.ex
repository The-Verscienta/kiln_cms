defmodule KilnCMS.Security.Posture do
  @moduledoc """
  The Security posture report (#2252): which security settings are on, for one
  site and (for a platform admin) the deployment, and what to fix first.

  Each line is a `Kiln.Security.Check`: the core's own (the modules under
  KilnCMS.Security.Posture.Checks), then every installed plugin's
  (`c:Kiln.Plugin.security_checks/0`), resolved by
  `KilnCMS.Security.Posture.Registry` and run by
  `KilnCMS.Security.Posture.Runner`, each in its own process under its own
  deadline.

  ## Read the resolver enforcement uses

  A core check answers from the same function the gate it reports on reads
  (`IdleTimeout`, `AdminAllowlist`, `PasswordPolicy`, `KilnCMS.Challenge`, the
  endpoint's compiled configuration), never from the settings row alone, so
  the page cannot say "on" for something enforcement ignores. Where that
  resolver fails open (answers "off" for a row it could not read), the check
  asks an existence-aware twin of it instead and answers `:unknown`.

  ## Unknown is not pass

  A check that could not tell answers `:unknown`; one that crashed, overran or
  answered nonsense is an `:error` row. Both count as a warning in `overall`,
  never as a pass: a page that turns green because a check broke is worse than
  no page.

  ## Nothing is stored

  The report is computed when asked (the `KilnCMS.Security.PostureReport`
  action), like the governance report. There is no table. The one copy kept
  is `snapshot/2`'s, for monitoring (#2521): in this node's cache for
  30 seconds, per site and scope set, without any result's details.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  alias Kiln.Security.Check.Context
  alias Kiln.Security.Check.Result
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Security.Posture.Registry, as: CheckRegistry
  alias KilnCMS.Security.Posture.Runner

  @docs_base "https://github.com/The-Verscienta/kiln_cms/blob/main/docs/security-posture.md"

  defmodule Entry do
    @moduledoc """
    One line of a posture report: the check's descriptor, its status, and its
    (sanitized) result.

    `status` is the result's own, or `:error` when the check did not produce
    one, with `error` saying why: `:crashed` (it raised, threw or exited),
    `:timeout`, `:invalid_result` (it answered something that is not a
    `Kiln.Security.Check.Result`) or `:busy` (no process was free to run it).
    The reason is for the page; the exception itself is only logged.
    """
    @enforce_keys [:id, :title, :scope, :source, :status]
    defstruct [
      :id,
      :title,
      :description,
      :scope,
      :source,
      :status,
      :error,
      :result,
      duration_ms: 0
    ]

    @type status :: Result.status() | :error
    @type error :: :crashed | :timeout | :invalid_result | :busy

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            description: String.t() | nil,
            scope: :site | :deployment,
            source: :core | {:plugin, String.t()} | :config,
            status: status(),
            error: error() | nil,
            result: Result.t() | nil,
            duration_ms: non_neg_integer()
          }
  end

  defmodule Report do
    @moduledoc """
    A posture report: its entries, the worst status among them (`overall`),
    how many of each status there are (`counts`), and when it ran.
    """
    @enforce_keys [:org_id, :scopes, :entries, :overall, :counts, :ran_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            org_id: String.t() | nil,
            scopes: [:site | :deployment],
            entries: [KilnCMS.Security.Posture.Entry.t()],
            overall: :pass | :warn | :fail,
            counts: %{atom() => non_neg_integer()},
            ran_at: DateTime.t()
          }
  end

  @statuses [:fail, :warn, :error, :unknown, :pass, :n_a]

  @slots KilnCMS.Security.Posture.Slots
  @max_per_org 3
  @snapshot_ttl :timer.seconds(30)

  @doc """
  Run `fun` holding one of the site's report slots: `{:ok, fun.()}`, or
  `{:error, :busy}` when #{@max_per_org} reports of `org_id` are already
  running on this node. Every report runs each check in its own task, so
  this is what keeps many open pages (or a held-down "Run checks again") from
  filling the checks' shared task supervisor.

  A slot is a `Registry` entry of the calling process: taken by registering
  and then counting, so two callers racing for the last slot can both be
  refused but never both admitted, and released when `fun` returns or the
  process dies.
  """
  @spec with_slot(String.t(), (-> result)) :: {:ok, result} | {:error, :busy}
        when result: term()
  def with_slot(org_id, fun) when is_binary(org_id) and is_function(fun, 0) do
    {:ok, _owner} = Registry.register(@slots, org_id, nil)

    try do
      if length(Registry.lookup(@slots, org_id)) > @max_per_org,
        do: {:error, :busy},
        else: {:ok, fun.()}
    after
      Registry.unregister(@slots, org_id)
    end
  end

  @doc "How many reports of one site may run at once on a node."
  @spec max_per_org() :: pos_integer()
  def max_per_org, do: @max_per_org

  @doc "The `Registry` the report slots are kept in."
  @spec slots() :: atom()
  def slots, do: @slots

  @doc """
  Which checks `actor` gets: the site's (`:site`), and for a platform
  administrator (effective platform role `:admin`, a live elevation grant
  included) the deployment's (`:deployment`) as well. The one rule, shared by
  the page's `:run` and monitoring's `:snapshot`.
  """
  @spec scopes_for(map() | nil) :: [:site] | [:site | :deployment]
  def scopes_for(actor) do
    if RoleGrant.effective_role(actor) == :admin, do: [:site, :deployment], else: [:site]
  end

  @doc "How long a `snapshot/2` is reused, in milliseconds."
  @spec snapshot_ttl() :: pos_integer()
  def snapshot_ttl, do: @snapshot_ttl

  @doc """
  The posture of the site `org_id` for monitoring (#2521): `report/3` in
  English, every result's details removed (they name people), and kept in
  this node's cache for #{div(@snapshot_ttl, 1000)} seconds under the site and
  the scope set (`KilnCMS.Cache.security_posture_key/2`), so a burst of
  monitors runs the checks at most once per window. Concurrent misses for one
  key wait on a single run. `ran_at` is when that run happened.

  Still bounded by `with_slot/2`: `{:error, :busy}` when the site's slots are
  full, and that answer is never cached.
  """
  @spec snapshot(String.t(), [:site | :deployment]) :: {:ok, Report.t()} | {:error, :busy}
  def snapshot(org_id, scopes) when is_binary(org_id) and is_list(scopes) do
    key = KilnCMS.Cache.security_posture_key(org_id, scopes)

    case KilnCMS.Cache.fetch(key, @snapshot_ttl, fn -> fresh_snapshot(org_id, scopes) end) do
      %Report{} = report -> {:ok, report}
      nil -> {:error, :busy}
    end
  end

  # `nil` when the site's slots are full: `KilnCMS.Cache.fetch/3` never caches
  # a `nil`, so a busy answer does not stick for the window.
  defp fresh_snapshot(org_id, scopes) do
    case with_slot(org_id, fn -> report(org_id, scopes, locale: "en") end) do
      {:ok, report} -> without_details(report)
      {:error, :busy} -> nil
    end
  end

  @doc "`report` with every result's `details` emptied."
  @spec without_details(Report.t()) :: Report.t()
  def without_details(%Report{entries: entries} = report) do
    %{report | entries: Enum.map(entries, &entry_without_details/1)}
  end

  defp entry_without_details(%Entry{result: %Result{} = result} = entry),
    do: %{entry | result: %{result | details: []}}

  defp entry_without_details(entry), do: entry

  @doc """
  The report for the site `org_id`, running the checks whose scope is one of
  `scopes` (`:site`, `:deployment`).

  Options: `:now` (default the clock) and `:locale` (default `"en"`), both
  handed to every check in its `Kiln.Security.Check.Context`.
  """
  @spec report(String.t(), [:site | :deployment], keyword()) :: Report.t()
  def report(org_id, scopes, opts \\ []) when is_binary(org_id) and is_list(scopes) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    locale = Keyword.get(opts, :locale) || "en"
    build_env = Application.get_env(:kiln_cms, :compile_env, :prod)

    descriptors =
      Gettext.with_locale(KilnCMSWeb.Gettext, locale, fn ->
        Enum.filter(CheckRegistry.checks(), &(&1.scope in scopes))
      end)

    entries =
      Runner.run(descriptors, fn
        :site -> %Context{org_id: org_id, build_env: build_env, now: now, locale: locale}
        :deployment -> %Context{org_id: nil, build_env: build_env, now: now, locale: locale}
      end)

    %Report{
      org_id: org_id,
      scopes: scopes,
      entries: entries,
      overall: overall(entries),
      counts: counts(entries),
      ran_at: now
    }
  end

  @doc """
  The worst status among `entries`: `:fail`, then `:warn` (an `:unknown` or
  an `:error` counts as one), then `:pass`. A report of only `:n_a` lines, or
  none, is `:pass`.
  """
  @spec overall([Entry.t()]) :: :pass | :warn | :fail
  def overall(entries) do
    statuses = Enum.map(entries, & &1.status)

    cond do
      :fail in statuses -> :fail
      Enum.any?(statuses, &(&1 in [:warn, :unknown, :error])) -> :warn
      true -> :pass
    end
  end

  @doc "How many entries have each status, every status present (zero or not)."
  @spec counts([Entry.t()]) :: %{atom() => non_neg_integer()}
  def counts(entries) do
    Enum.reduce(entries, Map.new(@statuses, &{&1, 0}), fn entry, acc ->
      Map.update(acc, entry.status, 1, &(&1 + 1))
    end)
  end

  @doc "The statuses in the order the page lists them: what to fix first, first."
  @spec statuses() :: [Entry.status()]
  def statuses, do: @statuses

  @doc "`entries` sorted for the page: failures first, not-applicable last, then by title."
  @spec sorted([Entry.t()]) :: [Entry.t()]
  def sorted(entries) do
    rank = @statuses |> Enum.with_index() |> Map.new()
    Enum.sort_by(entries, &{Map.fetch!(rank, &1.status), &1.title})
  end

  @doc """
  `items` as a result's details: the first nine, and an "and N more" line when
  there are more (a result carries at most ten details).
  """
  @spec listed([String.t()]) :: [String.t()]
  def listed(items) do
    {shown, rest} = Enum.split(items, 9)

    case length(rest) do
      0 -> shown
      1 -> shown ++ rest
      more -> shown ++ [gettext("and %{count} more", count: more)]
    end
  end

  @doc """
  The guide's URL, at `anchor` when given: what a core check links as "Learn
  more".
  """
  @spec docs_url(String.t() | nil) :: String.t()
  def docs_url(nil), do: @docs_base
  def docs_url(anchor), do: @docs_base <> "#" <> anchor
end
