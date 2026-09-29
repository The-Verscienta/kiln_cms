defmodule KilnCMS.Deprecations do
  @moduledoc """
  The runtime half of the deprecation policy (`docs/overlay-contract.md`,
  *When a covered surface must change*), first used in 0.12 (#1538).

  A deprecated function carries `@deprecated` and a deprecated `use` option
  warns at compile time: the compiler can see both. Some deprecated surfaces
  the compiler never sees — a route, a stored row, a job already sitting in the
  queue. Those log through `warn/3` when they are hit. The warning says what is
  deprecated, what to use instead and which release removes it, and carries
  `deprecated: <surface>` in its log metadata so an operator can filter for
  every one of them at once.

  ## Removed at 1.0 (#1543)

  Everything 0.12 deprecated is gone; see the *Removed at 1.0* table in
  `docs/overlay-contract.md`. Two kinds of data can still outlive the code that
  read it, and this module is where they are found and settled:

    * accounts that read gated content only through the removed `User.audiences`
      fallback — moved onto a default-organization membership by
      `migrate_legacy_audiences/0`, which `KilnCMS.Accounts.LegacyAudiencesWorker`
      runs after every deploy;
    * queued jobs in a pre-0.12 argument shape — cancelled with a logged error
      when they run (`cancel_legacy_job/2`). Drain the queue before upgrading.

  `report/0` lists both. `mix kiln.deprecations` prints it; in a release,
  `bin/kiln_cms eval 'KilnCMS.Release.deprecations()'`.
  """
  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.LegacyAffiliation

  @typedoc "The name a deprecated surface is logged under (`deprecated:` metadata)."
  @type surface :: atom()

  # The workers whose pre-0.12 job shapes 1.0 stopped reading. Each one's
  # current jobs always carry `org_id`; a job without it was enqueued by an
  # older release and still sits in the queue.
  @legacy_job_workers [
    "KilnCMS.Webhooks.DeliveryWorker",
    "KilnCMS.Newsletter.SendWorker",
    "KilnCMS.Newsletter.MailWorker"
  ]

  # A job in any of these states will still run. `completed`, `discarded` and
  # `cancelled` rows are history — nothing executes them.
  @pending_states ["available", "scheduled", "retryable", "executing"]

  @doc """
  Log that a deprecated surface was hit. `message` should name the surface,
  its replacement and the release that removes it; `metadata` is added to the
  log line.
  """
  @spec warn(surface(), String.t(), keyword()) :: :ok
  def warn(surface, message, metadata \\ []) do
    Logger.warning(message, Keyword.put(metadata, :deprecated, surface))
  end

  @doc """
  What a worker does with a job whose arguments are in a shape 1.0 no longer
  reads (#1543): log an error naming the worker and the arguments' keys, and
  cancel the job.

  Cancelled rather than raised, so Oban does not retry a job that can never
  succeed; logged at `:error`, so a queue that was not drained before the
  upgrade is visible rather than silently lost. The values are not logged — a
  newsletter job's arguments identify a subscriber.
  """
  @spec cancel_legacy_job(module(), map()) :: {:cancel, String.t()}
  def cancel_legacy_job(worker, args) do
    keys = args |> Map.keys() |> Enum.sort()

    Logger.error(
      "A #{inspect(worker)} job was cancelled: its arguments (keys #{inspect(keys)}) are " <>
        "in a shape from a release before 0.12, which 1.0 no longer runs (#1543). " <>
        "Its work was not done. Drain the queue before upgrading; " <>
        "`mix kiln.deprecations` lists jobs still in that shape."
    )

    {:cancel, "legacy job arguments (pre-0.12 shape), not run by 1.0"}
  end

  @doc """
  The data that outlived the code 1.0 removed:

    * `:legacy_audience_accounts` — accounts with `User.audiences` and no
      `OrgMembership`. Since 1.0 they read no gated content until
      `migrate_legacy_audiences/0` moves them onto a membership (which the
      post-deploy worker does on its own).
    * `:legacy_jobs` — queued jobs of the three workers still in a pre-0.12
      shape. 1.0 cancels each one when it runs.
  """
  @spec report() :: %{
          legacy_audience_accounts: [Accounts.User.t()],
          legacy_jobs: [%{id: integer(), worker: String.t(), state: String.t()}]
        }
  def report do
    %{
      # authorize?: false — operator tooling, run from a shell or `bin/kiln_cms
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
  Move every account `report/0` lists onto a membership: give it one on the
  default organization through
  `KilnCMS.Accounts.LegacyAffiliation.ensure_default_membership/2`, the one
  definition of that step — its standing role, any live temporary role with its
  expiry, and its audiences.

  That is exactly what the removed fallback granted on the default
  organization, so a single-site install sees no change. On any other site the
  account reads as a member elsewhere, which gets no audiences there — the
  fail-closed rule every other scope axis follows.

  Every account is attempted: one that fails is returned under `:failed` with
  its error and does not stop the rest. Idempotent — the membership write is an
  upsert that changes nothing on an existing row — so two nodes running it at
  once, or a rerun, is harmless.
  """
  @spec migrate_legacy_audiences() :: %{
          migrated: [Accounts.User.t()],
          failed: [{Accounts.User.t(), term()}]
        }
  def migrate_legacy_audiences do
    # authorize?: false — the same operator tooling as `report/0`, with no
    # actor; the list only feeds the membership write below.
    Accounts.list_legacy_audience_accounts!(authorize?: false)
    |> Enum.reduce(%{migrated: [], failed: []}, fn user, acc ->
      # authorize?: false — operator tooling with no actor; the membership
      # written grants exactly what the fallback granted on the default org,
      # so it widens nothing.
      case LegacyAffiliation.ensure_default_membership(user, authorize?: false) do
        {:ok, _membership} -> %{acc | migrated: [user | acc.migrated]}
        {:error, error} -> %{acc | failed: [{user, error} | acc.failed]}
      end
    end)
    |> Map.new(fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  @doc """
  What `mix kiln.deprecations` and `KilnCMS.Release.deprecations/1` run:
  `migrate_legacy_audiences/0` first when `migrate_audiences: true`, then
  `report/0`, printed through `shell`. `:ok` when nothing is left,
  `{:error, message}` otherwise.
  """
  @spec run_and_report(keyword(), (String.t() -> any())) :: :ok | {:error, String.t()}
  def run_and_report(opts, shell) do
    with :ok <- maybe_migrate(opts[:migrate_audiences], shell) do
      case print_report(shell) do
        :ok ->
          shell.("Nothing here depends on a surface 1.0 removed.")
          :ok

        {:pending, _report} ->
          {:error, "This instance still holds data 1.0 no longer reads; see above."}
      end
    end
  end

  defp maybe_migrate(true, shell) do
    %{migrated: migrated, failed: failed} = migrate_legacy_audiences()
    shell.("Moved #{length(migrated)} account(s) onto a default-organization membership.")

    case failed do
      [] ->
        :ok

      [{user, error} | _] ->
        {:error,
         "Could not give #{length(failed)} account(s) a membership; #{user.email}: " <>
           describe(error)}
    end
  end

  defp maybe_migrate(_flag, _shell), do: :ok

  @doc false
  def describe(error) when is_exception(error), do: Exception.message(error)
  def describe(error), do: inspect(error)

  defp print_report(shell) do
    %{legacy_audience_accounts: accounts, legacy_jobs: jobs} = report = report()

    shell.("Accounts on the removed User.audiences fallback: #{length(accounts)}")

    Enum.each(accounts, fn user ->
      shell.("  #{user.email}  #{Enum.map_join(user.audiences, ", ", &to_string/1)}")
    end)

    if accounts != [] do
      shell.("  Move them onto a membership: mix kiln.deprecations --migrate-audiences")
    end

    shell.("Queued jobs in a pre-0.12 argument shape: #{length(jobs)}")

    jobs
    |> Enum.frequencies_by(&{&1.worker, &1.state})
    |> Enum.sort()
    |> Enum.each(fn {{worker, state}, count} -> shell.("  #{worker} (#{state}): #{count}") end)

    if jobs != [] do
      shell.(
        "  1.0 cancels each of these when it runs, without doing its work. On 0.12, let the " <>
          "queue drain before upgrading."
      )
    end

    if accounts == [] and jobs == [], do: :ok, else: {:pending, report}
  end
end
