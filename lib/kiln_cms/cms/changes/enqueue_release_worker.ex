defmodule KilnCMS.CMS.Changes.EnqueueReleaseWorker do
  @moduledoc """
  Hands a claimed release (#500) to `KilnCMS.CMS.Workers.ReleaseWorker`.

      change {KilnCMS.CMS.Changes.EnqueueReleaseWorker, mode: :publish}
      change {KilnCMS.CMS.Changes.EnqueueReleaseWorker, mode: :rollback}

  Runs in `after_transaction` so the job is only enqueued once the claim itself
  committed — a claim that rolled back must not leave a worker chasing a release
  that is still `:scheduled`.

  Unlike `FireArtifacts`, an enqueue failure here is **not** swallowed: the job
  *is* the work. A release whose claim committed but whose worker was never
  enqueued would sit in `:publishing` forever with no site change and no error,
  which is the one outcome worse than failing loudly. The error is returned, so
  the claim's caller sees it.
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

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      with {:ok, release} <- result do
        enqueue(release, mode)
      end
    end)
  end

  defp enqueue(release, mode) do
    args = %{
      "release_id" => release.id,
      "org_id" => release.org_id,
      "mode" => to_string(mode)
    }

    case args |> ReleaseWorker.new() |> Oban.insert() do
      {:ok, _job} -> {:ok, release}
      {:error, reason} -> {:error, reason}
    end
  end
end
