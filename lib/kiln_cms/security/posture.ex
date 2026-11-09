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
  action), like the governance report. There is no table and no snapshot.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  alias Kiln.Security.Check.Context
  alias Kiln.Security.Check.Result
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
