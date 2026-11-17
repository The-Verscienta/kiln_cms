defmodule KilnCMS.Accounts.ErasureBackfill do
  @moduledoc """
  Applies to accounts erased by an earlier release what erasure does now.

  Erasure (`KilnCMS.Accounts.Changes.AnonymizeUser`) gains steps over time,
  and an account erased before a step existed keeps whatever that step would
  have removed. This pass finds those accounts and runs the missing steps on
  them. Today there is one:

    * **Newsletter subscriptions (#2991).** Erasure did not delete the
      subscriber rows linked to the account, so a confirmed subscription kept
      mailing the person's real address after they asked to be forgotten. For
      every erased account (`anonymized_at` set) that still has a linked row,
      `KilnCMS.Newsletter.forget_member/1` deletes them, on every site.

  Only linked rows (`newsletter_subscribers.user_id`), as erasure itself: a
  row added by hand at the same address was never the account's.

  ## When it runs

  `KilnCMS.Application` enqueues it on boot, ten minutes out, so migrations
  and a rolling deploy are normally over first. Deduplicated for a day at the
  database level, and idempotent: what it fixes stops matching, so a second
  run finds nothing to do. `config :kiln_cms, :erasure_backfill_on_boot,
  false` turns the boot enqueue off (the test and e2e builds do); `run/0`
  runs it by hand:

      bin/kiln_cms rpc "KilnCMS.Accounts.ErasureBackfill.run()"

  Only the orgs where an account still has rows are visited, not every org
  for every account.

  An account whose rows could not be deleted is logged (at warning) and
  counted under `:failed`, and the pass goes on to the next one. A run with
  any failure ends the job in error, so Oban retries it with backoff, up to
  three attempts; the uniqueness window covers the job's own retries, not
  just new inserts, so a boot meanwhile does not queue a second one. A retry
  finds only what is still left. After the last attempt the job is
  discarded, and the next boot queues a fresh one.
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

  @typedoc """
  What a run changed: how many erased accounts had their newsletter rows
  deleted, how many rows that was, and how many accounts failed.
  """
  @type result :: %{
          newsletter_accounts: non_neg_integer(),
          newsletter_subscribers: non_neg_integer(),
          failed: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = run()

    cond do
      result.failed > 0 ->
        Logger.warning("erasure backfill: #{inspect(result)}; retrying")
        {:error, "erasure backfill failed for #{result.failed} account(s)"}

      result.newsletter_accounts > 0 ->
        Logger.info("erasure backfill: #{inspect(result)}")
        :ok

      true ->
        :ok
    end
  end

  @doc "Run the pass over every erased account. See the moduledoc."
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo, KilnCMS.Repo)

    repo
    |> erased_with_subscribers()
    |> Enum.group_by(fn {user_id, _org_id, _count} -> user_id end)
    |> Enum.sort_by(fn {user_id, _rows} -> user_id end)
    |> Enum.reduce(
      %{newsletter_accounts: 0, newsletter_subscribers: 0, failed: 0},
      &forget_newsletter/2
    )
  end

  # Each erased account's linked subscriber rows, counted per org. Read
  # through Ecto across every org: this is a sweep over the whole instance,
  # and the delete itself goes through the Ash action, one org at a time,
  # in just the orgs listed here.
  defp erased_with_subscribers(repo) do
    repo.all(
      from(s in "newsletter_subscribers",
        join: u in "users",
        on: u.id == s.user_id,
        where: not is_nil(u.anonymized_at),
        group_by: [s.user_id, s.org_id],
        select: {type(s.user_id, Ecto.UUID), type(s.org_id, Ecto.UUID), count(s.id)}
      )
    )
  end

  defp forget_newsletter({user_id, rows}, acc) do
    org_ids = Enum.map(rows, fn {_user_id, org_id, _count} -> org_id end)
    :ok = KilnCMS.Newsletter.forget_member(user_id, org_ids)

    %{
      acc
      | newsletter_accounts: acc.newsletter_accounts + 1,
        newsletter_subscribers:
          acc.newsletter_subscribers + Enum.sum_by(rows, fn {_user_id, _org_id, n} -> n end)
    }
  rescue
    # `forget_member/2` raises once every listed org was tried and one
    # failed (logging each, with its org). One account's failure must not
    # stop the rest of the pass; it is counted, and fails the job.
    error ->
      Logger.warning(
        "erasure backfill could not forget newsletter rows for #{user_id}: " <>
          Exception.message(error)
      )

      %{acc | failed: acc.failed + 1}
  end

  @doc """
  Queue the pass ten minutes out, unless one is already queued or ran today.
  Never raises: a node must not fail to start because this could not be queued.
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
    Logger.warning("erasure backfill not queued: #{inspect(reason)}")
    :ok
  end
end
