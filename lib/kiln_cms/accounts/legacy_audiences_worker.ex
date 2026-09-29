defmodule KilnCMS.Accounts.LegacyAudiencesWorker do
  @moduledoc """
  The upgrade safety net for the `User.audiences` fallback 1.0 removed (#1543).

  Until 1.0, an account with **no memberships at all** read gated content
  through the global `User.audiences` column. 0.12 deprecated that fallback and
  shipped `mix kiln.deprecations --migrate-audiences` to move such accounts onto
  a membership; 1.0 removed it, so an account the operator did not migrate
  would silently lose its paid or granted access on upgrade. This job does the
  migration for them: `KilnCMS.Deprecations.migrate_legacy_audiences/0`, which
  gives each such account a default-organization membership carrying its
  audiences, standing role and any live temporary role — exactly what the
  fallback granted there.

  `KilnCMS.Application` enqueues it on every boot, like
  `KilnCMS.Events.BackfillWorker`, and for the same reasons.

  ## Why a job, and not a migration or a boot step

    * A codegen'd migration cannot call it: migrations run under
      `bin/kiln_cms eval` without the application, and the step is an Ash
      action (`LegacyAffiliation` writes through `OrgMembership`'s create, its
      upsert identity and its grant action), not SQL.
    * Run inside boot it would sit in front of HTTP coming up; as a job it runs
      on the `:default` queue moments after the node is serving. In that
      moment an unmigrated account sees only public content — fail-closed,
      never wider.
    * Every deploy path boots the application — `bin/migrate && bin/server`, a
      bare `mix phx.server`, a custom entrypoint — so nothing depends on an
      operator remembering an upgrade step.

  ## Deduplicated for a day, and cheap when there is nothing to do

  `unique` is a database constraint, so replicas booting together queue one job.
  On an instance with nothing left the pass is one read of `users` that returns
  no rows. The write is an upsert that changes nothing on an existing membership,
  so a concurrent `mix kiln.deprecations --migrate-audiences`, or a rerun, is
  harmless.

  An account whose membership could not be written is logged at `:error` and
  the job fails, so Oban retries it (`max_attempts: 3`); the accounts that did
  migrate are not revisited, because they no longer match the read.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 86_400,
      fields: [:worker],
      # Every incomplete state (Oban warns, and CI compiles with
      # `--warnings-as-errors`, if any is missing) plus `:completed`, so a
      # restart loop does not re-run a pass that already finished today.
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  require Logger

  alias KilnCMS.Deprecations

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{migrated: migrated, failed: failed} = Deprecations.migrate_legacy_audiences()

    if migrated != [] do
      Logger.warning(
        "Moved #{length(migrated)} account(s) off the User.audiences fallback 1.0 removed, " <>
          "onto a default-organization membership carrying the same audiences (#1543)."
      )
    end

    case failed do
      [] ->
        :ok

      failed ->
        Enum.each(failed, fn {user, error} ->
          Logger.error(
            "Could not move account #{user.id} off the removed User.audiences fallback: " <>
              "#{Deprecations.describe(error)}. It reads no gated content until it holds a " <>
              "membership; `mix kiln.deprecations --migrate-audiences` retries."
          )
        end)

        {:error, "#{length(failed)} account(s) could not be given a membership"}
    end
  end

  @doc """
  Queue the post-deploy pass, unless one is already queued or ran today.

  Called from `KilnCMS.Application` once the supervision tree is up. Never
  raises: a node must not fail to start because the job could not be queued,
  and the next boot tries again.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.error(
      "The User.audiences migration was not queued: #{inspect(reason)}. Accounts with " <>
        "audiences but no membership read no gated content until it runs; run " <>
        "`mix kiln.deprecations --migrate-audiences`."
    )

    :ok
  end
end
