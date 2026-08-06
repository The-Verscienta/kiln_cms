defmodule KilnCMS.CMS.Workers.ReleaseWorker do
  @moduledoc """
  Runs one content release's go-live or rollback (#500).

  A plain Oban worker rather than an AshOban trigger action, deliberately: the
  work *is* a transaction boundary that has to wrap N other Ash actions, and
  nesting that inside AshOban's own action transaction would leave no room to
  mark the release `:failed` — the failure write has to happen after the
  rollback, in a transaction of its own.

  AshOban still owns the *schedule*: `ContentRelease`'s `:go_live` trigger runs
  the minute cron per org, claims each due release (`:scheduled` →
  `:publishing`), and that claim enqueues this worker. The claim is what makes
  the cron safe — a release already `:publishing` no longer matches the trigger.

  **`max_attempts: 1`.** A release that aborted is in `:failed` with a reason an
  editor has to act on; silently retrying it a minute later would republish
  against the same broken item, and — worse — the second attempt would find the
  release in `:failed` rather than `:publishing` and do nothing while looking
  like a retry. Retrying is an explicit editorial act (reopen, fix, publish).
  """
  use Oban.Worker, queue: :scheduling, max_attempts: 1

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Releases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"release_id" => id, "org_id" => org_id} = args}) do
    mode = args["mode"] || "publish"

    case CMS.get_release(id, authorize?: false, tenant: org_id) do
      {:ok, release} ->
        run(release, mode)

      # Deleted between the claim and the job. Nothing to publish, nothing to
      # report to — a discarded job here would just be noise in the queue.
      _ ->
        Logger.warning("Release #{id} vanished before its #{mode} job ran")
        :ok
    end
  end

  # A release whose state no longer matches the job is not an error: the most
  # likely cause is a duplicate job (an at-least-once queue), and the claim
  # states exist precisely so the second one is a no-op.
  defp run(release, "publish"), do: report(Releases.publish(release), release, "go-live")
  defp run(release, "rollback"), do: report(Releases.roll_back(release), release, "rollback")

  defp run(release, mode) do
    Logger.error("Release #{release.id}: unknown worker mode #{inspect(mode)}")
    :ok
  end

  # The failure is already recorded on the release (state + reason + item), which
  # is where an editor looks. Returning `:ok` keeps Oban from retrying — see the
  # moduledoc — while the log line keeps it visible to operators.
  defp report({:ok, _updated}, _release, _what), do: :ok

  defp report({:error, {:unexpected_state, state}}, release, what) do
    Logger.info("Release #{release.id} #{what} skipped: already #{state}")
    :ok
  end

  defp report({:error, reason}, release, what) do
    Logger.error("Release #{release.id} #{what} failed: #{inspect(reason)}")
    :ok
  end
end
