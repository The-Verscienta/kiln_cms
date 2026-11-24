defmodule KilnCMS.CMS.StrandedReleaseItemSweep do
  @moduledoc """
  Cancels the `:pending` release items stranded on releases that can no
  longer ship them, on every site (#3072).

  A `KilnCMS.CMS.ReleaseItem` reserves its content record against every other
  release while it is `:pending`. Before 1.11.0 (#2740), an add that raced
  the go-live claim could insert an item the go-live never read, leaving it
  `:pending` on a `:published` release, and the record could never join
  another release. An old node (1.10.x or earlier) still serving during a
  rolling deploy to 1.11.0 or later can do the same. Nothing in the console
  frees such an item: the release no longer takes edits, and archiving it
  ends its group rollback.

  ## Which releases

  `KilnCMS.CMS.ContentRelease.closed_states/0`: `:published`, `:rolled_back`
  and `:archived`. No transition out of them reaches an editable state, so a
  pending item there never ships with its release. Left alone:

    * `:failed` keeps its items on purpose: reopening it retries them.
    * `:publishing` and `:rolling_back` are claims a worker owns. A pending
      item on a go-live is about to be applied; the next run (the next boot,
      or by hand) takes what a settled release left behind.

  Because closed states are absorbing for editability, the release's state is
  not checked again at write time. What is checked is the item:
  `:mark_cancelled` is a compare-and-swap on `status == :pending`, so an item
  another writer applied or freed since the read is never rewritten. That
  miss is a stale record, counted neither as cancelled nor as a failure.

  ## As whom

  The releases with stranded items are found with one Ecto query across every
  site; it only selects. Each release's pending items are then read and
  cancelled through Ash, in the item's own site (its `org_id`), under grants
  that already exist: the read as `KilnCMS.CMS.Housekeeping.system(:releases)`,
  the release worker's grant, with `authorize_with: :error` so a refused read
  fails rather than reading as nothing pending; the write as
  `KilnCMS.CMS.Bookkeeping.system/0`, the grant archiving uses for the same
  write. No `authorize?: false`.

  ## What it leaves behind

  Each cancelled item is logged at info: its site, release and that release's
  state, the item, its content and action. Nothing else announces it: an item
  has no notifier, audit entry, webhook event or PubSub message, just as an
  archive's own cancel has none. A logged record never shipped with its
  release; an editor can add it to a release again if it should still go live.

  ## When it runs

  `KilnCMS.Application` enqueues it on boot, ten minutes out, so migrations
  and a rolling deploy are normally over first; an old node still serving
  after that can strand an item, and the next boot's run, or a run by hand,
  takes it. Deduplicated for a day at the database level, and idempotent: a
  second run finds nothing pending on a closed release.
  `config :kiln_cms, :stranded_release_item_sweep_on_boot, false` turns the
  boot enqueue off (the test and e2e builds do);
  `KilnCMS.Release.cancel_stranded_release_items/1` runs it by hand, with
  `dry_run: true` to only list what it would cancel.

  A release whose items cannot be read, or one of whose items cannot be
  cancelled, is logged (at warning) and counted under `:failed`, and the
  sweep goes on to the next release; what it cancelled before the failure
  stays cancelled and is reported. Each cancel is its own transaction, so one
  bad row neither undoes the rest nor holds locks across sites. A run with any
  failure ends the job in error, so Oban retries it with backoff, up to three
  attempts.

  Once no supported upgrade path starts at 1.10.x or earlier, this module can
  be removed (in the next major release, at the latest).
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 86_400,
      fields: [:worker],
      states: [:scheduled, :available, :executing, :retryable, :suspended, :completed]
    ]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentRelease

  @typedoc """
  What a run did: the items cancelled (or, in a dry run, that would be), each
  as `%{org_id, release_id, release_state, item_id, content_type, content_id,
  action}`, how many releases failed, and whether it was a dry run.
  """
  @type result :: %{
          cancelled: non_neg_integer(),
          failed: non_neg_integer(),
          items: [map()],
          dry_run?: boolean()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = run()

    if result.failed > 0 do
      Logger.warning("stranded release item sweep: #{summary(result)}; retrying")
      {:error, "stranded release item sweep failed for #{result.failed} release(s)"}
    else
      if result.cancelled > 0, do: Logger.info("stranded release item sweep: #{summary(result)}")
      :ok
    end
  end

  @doc """
  Run the sweep. Options: `dry_run: true` reads and reports without
  cancelling; `org_id:` limits it to one site, and raises `ArgumentError` if
  it is not a UUID. See the moduledoc.

  `around_cancel:` is a test seam: a two-argument function called with each
  item, after the read that found it, and a zero-argument function that
  cancels it (resolving the actor as it runs) and must be called and its
  result returned. A test can act in that window, or run the cancel under
  another actor. Nothing else passes it.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    run_opts = %{
      dry_run?: opts[:dry_run] == true,
      around_cancel: Keyword.get(opts, :around_cancel, fn _item, cancel -> cancel.() end)
    }

    empty = %{cancelled: 0, failed: 0, items: [], dry_run?: run_opts.dry_run?}

    opts[:org_id]
    |> org_id!()
    |> releases()
    |> Enum.reduce(empty, &sweep(&1, &2, run_opts))
    |> Map.update!(:items, &Enum.reverse/1)
  end

  @doc "A one-line summary of a run's result."
  @spec summary(result()) :: String.t()
  def summary(%{dry_run?: true} = result),
    do: "would cancel #{result.cancelled}, #{result.failed} failed"

  def summary(result), do: "#{result.cancelled} cancelled, #{result.failed} failed"

  # Cast here, not in the query: an `org_id:` that is not a UUID would
  # otherwise surface as an `Ecto.Query.CastError` from deep inside the read.
  defp org_id!(nil), do: nil

  defp org_id!(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "org_id is not a UUID: #{inspect(org_id)}"
    end
  end

  # Each closed release with a pending item, per item site. Read through Ecto
  # across every site: this is a sweep over the whole instance, and each
  # release's items are then read and cancelled through Ash, in their own
  # site. Grouped by the ITEM's org, so an item an older release wrote into
  # another site than its release's is still read and cancelled where it is.
  defp releases(org_id) do
    closed = Enum.map(ContentRelease.closed_states(), &Atom.to_string/1)

    query =
      from(i in "release_items",
        join: r in "content_releases",
        on: r.id == i.release_id,
        where: i.status == "pending" and r.state in ^closed,
        group_by: [i.org_id, i.release_id, r.state],
        order_by: [i.org_id, i.release_id],
        select: {type(i.org_id, Ecto.UUID), type(i.release_id, Ecto.UUID), r.state}
      )

    query =
      if org_id,
        do: from(i in query, where: i.org_id == type(^org_id, Ecto.UUID)),
        else: query

    query
    |> KilnCMS.Repo.all()
    |> Enum.map(fn {org, release, state} -> {org, release, closed_state(state)} end)
  end

  # Back to the atom, from the closed list itself: the query only matched those.
  defp closed_state(state),
    do: Enum.find(ContentRelease.closed_states(), &(Atom.to_string(&1) == state))

  defp sweep({org_id, release_id, state}, acc, run_opts) do
    read_opts = [
      actor: CMS.Housekeeping.system(:releases),
      tenant: org_id,
      authorize_with: :error
    ]

    with {:ok, items} <- CMS.list_release_items_with_status(release_id, :pending, read_opts),
         {:ok, cancelled} <- cancel(items, org_id, run_opts) do
      record(acc, cancelled, org_id, state, run_opts.dry_run?)
    else
      {:error, error, cancelled} ->
        acc |> record(cancelled, org_id, state, false) |> failed(error, org_id, release_id)

      {:error, error} ->
        failed(acc, error, org_id, release_id)
    end
  end

  defp cancel(items, _org_id, %{dry_run?: true}), do: {:ok, items}

  # One at a time, each a compare-and-swap in its own transaction.
  defp cancel(items, org_id, run_opts) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, cancelled} ->
      run_opts.around_cancel.(item, fn ->
        cancel_one(item, cancelled, actor: CMS.Bookkeeping.system(), tenant: org_id)
      end)
    end)
    |> case do
      {:ok, cancelled} -> {:ok, Enum.reverse(cancelled)}
      {:error, error, cancelled} -> {:error, error, Enum.reverse(cancelled)}
    end
  end

  defp cancel_one(item, cancelled, opts) do
    case CMS.mark_release_item_cancelled(item, %{}, opts) do
      {:ok, done} ->
        {:cont, {:ok, [done | cancelled]}}

      {:error, error} ->
        # Applied or freed by another writer since the read: not ours.
        if CMS.Releases.stale?(error),
          do: {:cont, {:ok, cancelled}},
          else: {:halt, {:error, error, cancelled}}
    end
  end

  defp record(acc, items, org_id, state, dry_run?) do
    described = Enum.map(items, &describe(&1, org_id, state))
    Enum.each(described, &log(&1, dry_run?))

    %{
      acc
      | cancelled: acc.cancelled + length(described),
        items: Enum.reverse(described, acc.items)
    }
  end

  defp failed(acc, error, org_id, release_id) do
    Logger.warning(
      "stranded release item sweep could not cancel the items of release #{release_id} " <>
        "in org #{org_id}: " <> Exception.message(Ash.Error.to_error_class(error))
    )

    %{acc | failed: acc.failed + 1}
  end

  defp describe(item, org_id, state),
    do: %{
      org_id: org_id,
      release_id: item.release_id,
      release_state: state,
      item_id: item.id,
      content_type: item.content_type,
      content_id: item.content_id,
      action: item.action
    }

  defp log(item, dry_run?) do
    verb = if dry_run?, do: "would cancel", else: "cancelled"

    Logger.info(
      "stranded release item sweep #{verb} item #{item.item_id} " <>
        "(#{item.action} #{item.content_type} #{item.content_id}) " <>
        "of #{item.release_state} release #{item.release_id} in org #{item.org_id}: " <>
        "it never shipped with that release; add the record to a release again " <>
        "if it should still go live"
    )
  end

  @doc """
  Queue the sweep ten minutes out, unless one is already queued or ran
  today. Never raises: a node must not fail to start because this could not
  be queued.
  """
  @spec enqueue() :: :ok
  def enqueue do
    case %{} |> new(schedule_in: 600) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_failure(reason)
    end
  rescue
    error -> log_failure(error)
  end

  defp log_failure(reason) do
    Logger.warning("stranded release item sweep not queued: #{inspect(reason)}")
    :ok
  end
end
