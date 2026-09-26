defmodule KilnCMS.Deprecations do
  @moduledoc """
  The runtime half of the deprecation policy (`docs/overlay-contract.md`,
  *When a covered surface must change*), first used in 0.12 (#1538).

  A deprecated function carries `@deprecated` and a deprecated `use` option
  warns at compile time: the compiler can see both. Some deprecated surfaces
  the compiler never sees — a route, a stored row, a job already sitting in the
  queue. Those log a `Logger.warning` here when they are hit. The warning says
  what is deprecated, what to use instead and that 1.0 removes it, and carries
  `deprecated: <surface>` in its log metadata so an operator can filter for
  every one of them at once.

  ## Deprecated in 0.12, removed at 1.0 (#1543)

  | Surface | Marker | Instead |
  |---|---|---|
  | `published?:` on `use KilnCMS.CMS.Content` | compile-time warning | drop the option; every type has the `:published` read |
  | the `/editor/pages/:id` and `/editor/posts/:id` routes | `:editor_route_alias`, logged on each visit | `/editor/content/page/:id`, `/editor/content/post/:id` |
  | `User.audiences` for an account with no memberships | `:legacy_user_audiences`, logged once per account per boot | an `OrgMembership` carrying the audiences — `mix kiln.deprecations --migrate-audiences` |
  | job args without `org_id` (webhook, newsletter send and newsletter mail workers), and the pre-ledger webhook shape | `:legacy_job_args`, logged on each run | drain the queue before upgrading to 1.0 — `mix kiln.deprecations` counts what is left |
  | the legacy block bridge (#1537) | `@deprecated` | see `KilnCMS.CMS.TypedBlocks` |

  `report/0` finds the data an upgrade to 1.0 would strand: the accounts still
  reading through the audiences fallback and the queued jobs still in a legacy
  shape. `mix kiln.deprecations` prints it; in a release,
  `bin/kiln_cms eval 'KilnCMS.Release.deprecations()'`.
  """
  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.Accounts

  @table __MODULE__

  @typedoc "The name a deprecated surface is logged under (`deprecated:` metadata)."
  @type surface :: :editor_route_alias | :legacy_user_audiences | :legacy_job_args

  # The workers whose pre-1.0 job shapes 1.0 stops reading. Each one's current
  # jobs always carry `org_id`; a job without it was enqueued by an older
  # release and still sits in the queue.
  @legacy_job_workers [
    "KilnCMS.Webhooks.DeliveryWorker",
    "KilnCMS.Newsletter.SendWorker",
    "KilnCMS.Newsletter.MailWorker"
  ]

  # A job in any of these states will still run. `completed`, `discarded` and
  # `cancelled` rows are history — 1.0 never executes them.
  @pending_states ["available", "scheduled", "retryable", "executing"]

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # The server only owns the table: `warn_once/4` writes it from the caller's
    # process, so a hot path never waits on a message.
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Log that a deprecated surface was hit. `message` should name the surface,
  its replacement and the 1.0 removal; `metadata` is added to the log line.
  """
  @spec warn(surface(), String.t(), keyword()) :: :ok
  def warn(surface, message, metadata \\ []) do
    Logger.warning(message, Keyword.put(metadata, :deprecated, surface))
  end

  @doc """
  `warn/3`, at most once per `{surface, key}` for the life of the node — for a
  surface hit on every request, where one line per account is the signal and
  one per request is noise.
  """
  @spec warn_once(surface(), term(), String.t(), keyword()) :: :ok
  def warn_once(surface, key, message, metadata \\ []) do
    if first?({surface, key}), do: warn(surface, message, metadata), else: :ok
  end

  # Without the table (a script that never started the application) every hit
  # is the first: a duplicated warning is better than a lost one.
  defp first?(key) do
    :ets.insert_new(@table, {key})
  rescue
    ArgumentError -> true
  end

  @doc """
  The org a queued job runs under: its `org_id` arg, or — for a job enqueued
  before the arg existed, a shape 1.0 stops reading — the default org, with a
  `:legacy_job_args` warning.
  """
  @spec job_org_id(map(), module()) :: String.t()
  def job_org_id(%{"org_id" => org_id}, _worker) when is_binary(org_id), do: org_id

  def job_org_id(_args, worker) do
    warn_legacy_job(worker, "has no `org_id` and ran against the default organization")
    Accounts.default_org_id()
  end

  @doc """
  Log that `worker` ran a job in a deprecated argument shape; `what` says how
  the shape differs and what the worker did with it.
  """
  @spec warn_legacy_job(module(), String.t()) :: :ok
  def warn_legacy_job(worker, what) do
    warn(
      :legacy_job_args,
      "A #{inspect(worker)} job #{what}. That argument shape is from a release " <>
        "before 0.12 and is deprecated; 1.0 no longer runs it. Let the queue drain " <>
        "before upgrading to 1.0 (`mix kiln.deprecations` counts what is left).",
      worker: inspect(worker)
    )
  end

  @doc """
  The data an upgrade to 1.0 would strand:

    * `:legacy_audience_accounts` — accounts with `User.audiences` and no
      `OrgMembership`, whose gated-content access comes only from the fallback
      1.0 removes. `migrate_legacy_audiences/0` moves them onto a membership.
    * `:legacy_jobs` — queued jobs of the three workers still in a shape 1.0
      will not read. Let the queue drain (or cancel them) before upgrading.
  """
  @spec report() :: %{
          legacy_audience_accounts: [%Accounts.User{}],
          legacy_jobs: [%{id: integer(), worker: String.t(), state: String.t()}]
        }
  def report do
    %{
      # `authorize?: false`: operator tooling, run from a shell or `bin/kiln_cms
      # eval` with no request and no actor. The action's policy admits only a
      # platform admin, and nothing here is reachable from a web surface.
      legacy_audience_accounts: Accounts.list_legacy_audience_accounts!(authorize?: false),
      legacy_jobs: legacy_jobs()
    }
  end

  defp legacy_jobs do
    workers = @legacy_job_workers
    states = @pending_states

    # `Oban.Job` is Oban's own Ecto schema, not an Ash resource — there is no
    # code interface to go through. `?` is jsonb's key-exists operator.
    from(j in Oban.Job,
      where: j.worker in ^workers and j.state in ^states,
      where:
        fragment("NOT (? \\? 'org_id')", j.args) or
          fragment("(?->>'org_id') IS NULL", j.args),
      order_by: [asc: j.id],
      select: %{id: j.id, worker: j.worker, state: j.state}
    )
    |> KilnCMS.Repo.all()
  end

  @doc """
  Move every account `report/0` lists off the `User.audiences` fallback: give
  it a membership on the default organization carrying its audiences and its
  standing role.

  That is exactly what the fallback grants on the default organization, so a
  single-site install sees no change. On any other site the account now reads
  as a member elsewhere, which gets no audiences there — the fail-closed rule
  every other scope axis already follows. A live temporary role grant on the
  account is not copied; it runs out on its own. Returns the migrated accounts.
  """
  @spec migrate_legacy_audiences() :: {:ok, [%Accounts.User{}]} | {:error, term()}
  def migrate_legacy_audiences do
    org_id = Accounts.default_org_id()

    # `authorize?: false` on both calls: the same operator tooling as
    # `report/0`, with no actor. The membership written grants exactly what
    # the fallback already grants on the default org, so it widens nothing.
    Accounts.list_legacy_audience_accounts!(authorize?: false)
    |> Enum.reduce_while({:ok, []}, fn user, {:ok, done} ->
      case Accounts.create_org_membership(
             %{
               organization_id: org_id,
               user_id: user.id,
               role: user.role,
               audiences: user.audiences
             },
             # `authorize?: false`: see the comment above the read.
             authorize?: false
           ) do
        {:ok, _membership} -> {:cont, {:ok, [user | done]}}
        {:error, error} -> {:halt, {:error, {user.email, error}}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  @doc """
  What `mix kiln.deprecations` and `KilnCMS.Release.deprecations/1` run:
  `migrate_legacy_audiences/0` first when `migrate_audiences: true`, then
  `report/0`, printed through `shell`. `:ok` when nothing would be stranded,
  `{:error, message}` otherwise.
  """
  @spec run_and_report(keyword(), (String.t() -> any())) :: :ok | {:error, String.t()}
  def run_and_report(opts, shell) do
    with :ok <- maybe_migrate(opts[:migrate_audiences], shell) do
      case print_report(shell) do
        :ok ->
          shell.("Nothing here depends on a surface 1.0 removes.")
          :ok

        {:pending, _report} ->
          {:error, "This instance still depends on surfaces 1.0 removes; see above."}
      end
    end
  end

  defp maybe_migrate(true, shell) do
    case migrate_legacy_audiences() do
      {:ok, users} ->
        shell.("Moved #{length(users)} account(s) onto a default-organization membership.")
        :ok

      {:error, {email, error}} ->
        message = if is_exception(error), do: Exception.message(error), else: inspect(error)
        {:error, "Could not give #{email} a membership: #{message}"}
    end
  end

  defp maybe_migrate(_flag, _shell), do: :ok

  defp print_report(shell) do
    %{legacy_audience_accounts: accounts, legacy_jobs: jobs} = report = report()

    shell.("Accounts on the legacy User.audiences fallback: #{length(accounts)}")

    Enum.each(accounts, fn user ->
      shell.("  #{user.email}  #{Enum.map_join(user.audiences, ", ", &to_string/1)}")
    end)

    if accounts != [] do
      shell.("  Move them onto a membership: mix kiln.deprecations --migrate-audiences")
    end

    shell.("Queued jobs in a pre-1.0 argument shape: #{length(jobs)}")

    jobs
    |> Enum.frequencies_by(&{&1.worker, &1.state})
    |> Enum.sort()
    |> Enum.each(fn {{worker, state}, count} -> shell.("  #{worker} (#{state}): #{count}") end)

    if jobs != [] do
      shell.("  Let the queue drain, or cancel them, before upgrading to 1.0.")
    end

    if accounts == [] and jobs == [], do: :ok, else: {:pending, report}
  end
end
