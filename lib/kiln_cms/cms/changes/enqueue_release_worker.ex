defmodule KilnCMS.CMS.Changes.EnqueueReleaseWorker do
  @moduledoc """
  Hands a claimed release (#500) to `KilnCMS.CMS.Workers.ReleaseWorker`.

      change {KilnCMS.CMS.Changes.EnqueueReleaseWorker, mode: :publish}
      change {KilnCMS.CMS.Changes.EnqueueReleaseWorker, mode: :rollback}

  Runs in `after_action` — **inside** the claim's own transaction, not after it.

  That placement is the whole point. `:publishing` and `:rolling_back` mean "a
  worker owns this release right now", so a claim that commits without its job
  leaves the release wedged in that state forever, with its items still
  reserving their content against every other release and no button that gets
  out. An `after_transaction` hook cannot prevent that: by the time it runs the
  claim has already committed, and returning an error only tells the caller to
  "try again" — the one thing that no longer works.

  Oban shares `KilnCMS.Repo`, so inserting here makes the job part of the same
  transaction: it becomes visible exactly when the claim does, and if the insert
  fails the claim rolls back with it and the release stays `:scheduled`.

  Uniqueness on the job is defence in depth behind the compare-and-swap `filter`
  on `:start` / `:start_rollback`: a duplicate enqueue for a release already
  queued collapses rather than running the bundle twice.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Workers.ReleaseWorker

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :mode) do
      {:ok, mode} when mode in [:publish, :rollback] -> {:ok, opts}
      _ -> {:error, "EnqueueReleaseWorker requires mode: :publish or mode: :rollback"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    mode = Keyword.fetch!(opts, :mode)

    Ash.Changeset.after_action(changeset, fn _changeset, release ->
      enqueue(release, mode)
    end)
  end

  defp enqueue(release, mode) do
    args = %{
      "release_id" => release.id,
      "org_id" => release.org_id,
      "mode" => to_string(mode)
    }

    unique = [unique: [keys: [:release_id, :mode], states: [:available, :scheduled, :executing]]]

    case args |> ReleaseWorker.new(unique) |> Oban.insert() do
      {:ok, _job} -> {:ok, release}
      {:error, reason} -> {:error, reason}
    end
  end
end
