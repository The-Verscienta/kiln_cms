defmodule KilnCMS.Accounts.ErasureBackfill do
  @moduledoc """
  Applies to accounts erased by an earlier release what erasure does now.

  Erasure (`KilnCMS.Accounts.Changes.AnonymizeUser`) gains steps over time,
  and an account erased before a step existed keeps whatever that step would
  have removed. This pass finds those accounts and runs the missing steps on
  them. Today there are three:

    * **Site memberships that still grant (#2774).** Erasure left the
      account's memberships as they were, so a tombstone kept its site tier,
      a live temporary tier and its audiences: it stayed on the admin and
      assignee rosters and could read gated content. Every membership of an
      erased account that still grants something (`AnonymizeUser.granting/0`)
      is demoted with `OrgMembership.:erase`, as erasure now does. The rows
      stay, as erasure keeps them.
    * **Newsletter subscriptions (#2991).** Erasure did not delete the
      subscriber rows linked to the account, so a confirmed subscription kept
      mailing the person's real address after they asked to be forgotten. For
      every erased account (`anonymized_at` set) that still has a linked row,
      `KilnCMS.Newsletter.forget_member/1` deletes them, on every site.
      Only linked rows (`newsletter_subscribers.user_id`), as erasure itself:
      a row added by hand at the same address was never the account's.
    * **What erasure deletes since #2514.** An account erased before then
      kept its Web Push subscriptions (a way to reach the person's device),
      its private saved views, the notifications addressed to it, and the
      audiences on its own row (`users.audiences`). The pass deletes the
      first three, as erasure does (shared saved views are the team's and
      stay), and clears the audiences. Left in place, those audiences would
      also put the tombstone in the legacy-audiences report
      (`User.:legacy_audience_accounts`, which now leaves erased accounts out
      as well).

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

  An account whose memberships could not be demoted, or whose rows could not
  be deleted or audiences cleared, is logged (at warning) and
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

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Changes.AnonymizeUser
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.Accounts.User

  @typedoc """
  What a run changed: how many memberships of erased accounts were demoted;
  how many erased accounts had their newsletter rows deleted and how many
  rows that was; how many erased accounts had their audiences cleared; how
  many push subscriptions, private saved views and notifications were
  deleted; and how many failures there were (an account counts once for
  each step that failed for it).
  """
  @type result :: %{
          memberships: non_neg_integer(),
          newsletter_accounts: non_neg_integer(),
          newsletter_subscribers: non_neg_integer(),
          audiences: non_neg_integer(),
          push_subscriptions: non_neg_integer(),
          saved_views: non_neg_integer(),
          notifications: non_neg_integer(),
          failed: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = run()

    cond do
      result.failed > 0 ->
        Logger.warning("erasure backfill: #{inspect(result)}; retrying")
        {:error, "erasure backfill failed for #{result.failed} account(s)"}

      Enum.any?(result, fn {_step, count} -> count > 0 end) ->
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

    empty = %{
      memberships: 0,
      newsletter_accounts: 0,
      newsletter_subscribers: 0,
      audiences: 0,
      push_subscriptions: 0,
      saved_views: 0,
      notifications: 0,
      failed: 0
    }

    demoted =
      granting_memberships()
      |> Enum.group_by(& &1.user_id, & &1.id)
      |> Enum.sort_by(fn {user_id, _ids} -> user_id end)
      |> Enum.reduce(empty, &demote_memberships/2)

    repo
    |> erased_with_subscribers()
    |> Enum.group_by(fn {user_id, _org_id, _count} -> user_id end)
    |> Enum.sort_by(fn {user_id, _rows} -> user_id end)
    |> Enum.reduce(demoted, &forget_newsletter/2)
    |> clear_audiences(repo)
    |> remove_push_subscriptions(repo)
    |> forget_per_org(erased_with_rows(repo, :saved_views), :saved_views)
    |> forget_per_org(erased_with_rows(repo, :notifications), :notifications)
  end

  # The memberships of erased accounts that still grant something. Global
  # (memberships are not tenant-scoped), so one read covers every site.
  defp granting_memberships do
    query =
      OrgMembership
      |> Ash.Query.filter(not is_nil(user.anonymized_at) and ^AnonymizeUser.granting())
      |> Ash.Query.select([:id, :user_id])

    # authorize?: false — a sweep over every account's memberships; the read
    # policy is self-only, and `:erase` below is refused to every actor.
    Accounts.list_org_memberships!(authorize?: false, query: query)
  end

  defp demote_memberships({user_id, ids}, acc) do
    # authorize?: false — as `granting_memberships/0`; the filter pins the
    # write to the rows that read found.
    OrgMembership
    |> Ash.Query.filter(id in ^ids and ^AnonymizeUser.granting())
    |> Ash.bulk_update!(:erase, %{},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )

    %{acc | memberships: acc.memberships + length(ids)}
  rescue
    # One account's failure must not stop the rest of the pass, as below.
    error ->
      Logger.warning(
        "erasure backfill could not demote the memberships of #{user_id}: " <>
          Exception.message(error)
      )

      %{acc | failed: acc.failed + 1}
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

  # The erased accounts whose own row still holds audiences. Erasure has
  # cleared them since #2514, in SQL (see `AnonymizeUser`), for the reason it
  # gives there.
  defp clear_audiences(acc, repo) do
    ids =
      repo.all(
        from(u in "users",
          where:
            not is_nil(u.anonymized_at) and
              fragment("coalesce(cardinality(?), 0) > 0", u.audiences),
          select: type(u.id, Ecto.UUID)
        )
      )

    clear_audiences(acc, ids, length(ids))
  end

  defp clear_audiences(acc, [], 0), do: acc

  defp clear_audiences(acc, ids, count) do
    # authorize?: false — `:sync_billing_audiences` refuses any actor-carrying
    # call by design (as in `AnonymizeUser.clear_audiences/1`), and the
    # filter pins the write to erased accounts the read above found.
    User
    |> Ash.Query.filter(
      id in ^ids and not is_nil(anonymized_at) and
        fragment("coalesce(cardinality(?), 0) > 0", audiences)
    )
    |> Ash.bulk_update!(:sync_billing_audiences, %{audiences: []},
      authorize?: false,
      strategy: [:atomic, :atomic_batches, :stream],
      return_records?: false,
      return_errors?: true
    )

    %{acc | audiences: acc.audiences + count}
  rescue
    # Counted once for each account in the statement, and fails the job.
    error ->
      Logger.warning(
        "erasure backfill could not clear the audiences of #{count} erased account(s): " <>
          Exception.message(error)
      )

      %{acc | failed: acc.failed + count}
  end

  # One statement for every erased account's devices: push subscriptions are
  # not tenant-scoped (their `org_id` is the site that minted the key).
  defp remove_push_subscriptions(acc, repo) do
    rows =
      repo.all(
        from(p in "push_subscriptions",
          join: u in "users",
          on: u.id == p.user_id,
          where: not is_nil(u.anonymized_at),
          select: {type(p.user_id, Ecto.UUID), type(p.id, Ecto.UUID)}
        )
      )

    remove_push_subscriptions(acc, rows, Enum.map(rows, &elem(&1, 1)))
  end

  defp remove_push_subscriptions(acc, [], []), do: acc

  defp remove_push_subscriptions(acc, rows, ids) do
    # As `KilnCMS.Push.system/0`, which the destroy policy admits: each id came
    # from the read above, of an erased account's devices.
    PushSubscription
    |> Ash.Query.filter(id in ^ids)
    |> Accounts.remove_push_subscription!(
      actor: KilnCMS.Push.system(),
      bulk_options: [
        authorize_with: :error,
        strategy: [:atomic, :atomic_batches, :stream],
        return_records?: false,
        return_errors?: true
      ]
    )

    %{acc | push_subscriptions: acc.push_subscriptions + length(ids)}
  rescue
    error ->
      accounts = rows |> Enum.uniq_by(&elem(&1, 0)) |> length()

      Logger.warning(
        "erasure backfill could not delete the push subscriptions of #{accounts} " <>
          "erased account(s): " <> Exception.message(error)
      )

      %{acc | failed: acc.failed + accounts}
  end

  # Each erased account's private saved views or own notifications, counted
  # per org, for the per-org deletes below. Both are tenant-scoped with no
  # tenant-bypassing action, so this read is what keeps the delete to the
  # orgs where the account has rows.
  defp erased_with_rows(repo, :saved_views) do
    repo.all(
      from(v in "saved_views",
        join: u in "users",
        on: u.id == v.owner_id,
        where: not is_nil(u.anonymized_at) and v.shared == false,
        group_by: [v.owner_id, v.org_id],
        select: {type(v.owner_id, Ecto.UUID), type(v.org_id, Ecto.UUID), count(v.id)}
      )
    )
  end

  defp erased_with_rows(repo, :notifications) do
    repo.all(
      from(n in "notifications",
        join: u in "users",
        on: u.id == n.user_id,
        where: not is_nil(u.anonymized_at),
        group_by: [n.user_id, n.org_id],
        select: {type(n.user_id, Ecto.UUID), type(n.org_id, Ecto.UUID), count(n.id)}
      )
    )
  end

  defp forget_per_org(acc, rows, step) do
    rows
    |> Enum.group_by(fn {user_id, _org_id, _count} -> user_id end)
    |> Enum.sort_by(fn {user_id, _rows} -> user_id end)
    |> Enum.reduce(acc, &forget_in_orgs(&1, &2, step))
  end

  defp forget_in_orgs({user_id, rows}, acc, step) do
    org_ids = Enum.map(rows, fn {_user_id, org_id, _count} -> org_id end)
    :ok = forget(step, user_id, org_ids)

    Map.update!(acc, step, &(&1 + Enum.sum_by(rows, fn {_user_id, _org_id, n} -> n end)))
  rescue
    # Both raise once every listed org was tried and one failed (logging
    # each, with its org), as `forget_newsletter/2` above.
    error ->
      Logger.warning(
        "erasure backfill could not delete the #{step} of #{user_id}: " <>
          Exception.message(error)
      )

      %{acc | failed: acc.failed + 1}
  end

  defp forget(:saved_views, user_id, org_ids),
    do: KilnCMS.CMS.SavedViews.forget_private_views(user_id, org_ids)

  defp forget(:notifications, user_id, org_ids),
    do: KilnCMS.Notifications.forget_recipient(user_id, org_ids)

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
