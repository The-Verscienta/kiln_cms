defmodule KilnCMS.CMS.Releases do
  @moduledoc """
  Go-live and rollback for content releases (#500) — the part that actually
  moves content.

  ## The transaction is the feature

  A release publishes N items through the **normal** per-item actions
  (`:publish` / `:unpublish` on `KilnCMS.CMS.Content`), because those actions are
  what carry the state machine, version history, the tamper-evident audit chain,
  the artifact re-fire wave and the webhook fan-out. Reimplementing publishing
  here would produce content that is live but has none of that.

  Every one of those side effects is a **database write** — `NotifyWebhooks`
  records ledger rows and inserts an Oban job, `FireArtifacts` inserts an Oban
  job, automation dispatch inserts an Oban job, `Governance.Chain` writes anchor
  rows — and Oban shares `KilnCMS.Repo`. Nothing on the publish path makes a
  synchronous HTTP or object-store call; the POSTs and renders are jobs that only
  become visible on commit.

  So one `Repo.transaction` around all N items is genuinely all-or-nothing: item
  7 failing rolls back items 1–6 **and** the webhooks, fires and automation jobs
  they queued. No observer ever sees a half-live campaign, which is the promise
  the issue makes. The release lands in `:failed` naming the item that broke, and
  the site is exactly as it was.

  The cost is honest and worth stating: one long-running transaction holding row
  locks on every item for the duration. `@transaction_timeout_ms` bounds it.

  ## Already-true items are skipped, not failed

  If an editor publishes a page by hand before the release fires, the item's
  desired end state already holds. Failing the whole release for that would be
  pedantic and would strand a launch at 09:00 over a no-op. Such items are marked
  `:skipped` — recorded, visible in the console, and deliberately **not** touched
  by a later rollback, because the release did not put them there.

  A genuinely impossible transition (an archived record, a trashed one, a content
  type that no longer exists) is a real failure and aborts the release.

  ## Rollback

  Rollback restores each `:applied` item's captured `prior_state` and, where the
  record has since drifted, `prior_version_id` — in reverse order, in one
  transaction, with the same all-or-nothing guarantee. See `roll_back/1`.

  ## A known, accepted gap in notifications

  Ash drops a resource's notifications for any action running inside a
  transaction it did not open, so every write here asks for them back and
  replays them on commit (`notifying/1`). Four internal writes are still missed,
  because they are made by the publish path's own hooks rather than by us:
  `Page.set_published_version_id` (the published-version pointer),
  `HistoryAnchor.create` (the audit chain), `PublishedArtifact.destroy`, and the
  `WebhookDelivery` rows `Webhooks.dispatch/3` records. Threading notifications
  out of those shared changes would touch the whole publish path for little gain
  — the meaningful `:publish` / `:unpublish` notification is captured and
  delivered, and the missed ones are bookkeeping writes no subscriber acts on.
  """
  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Repo
  alias KilnCMS.Webhooks

  # A release of a few hundred items renders and re-fires nothing synchronously
  # (all of that is queued), but it does run N publish transactions' worth of
  # writes back to back. Two minutes is far above any realistic release and far
  # below "a stuck worker holds locks all afternoon".
  @transaction_timeout_ms :timer.minutes(2)

  @typedoc "Why an item cannot be applied, or that it needs no work."
  @type classification ::
          :apply | {:skip, :already_in_state} | {:error, String.t()}

  @doc """
  PubSub topic a release's console page listens on for its worker's verdict.

  Go-live runs off-request, so the page that started it has nothing to re-read
  at the moment it starts — the claim commits microseconds before the worker
  does any work. Without this the console renders "Publishing" and stays there.
  """
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(release_id), do: "content_release:#{release_id}"

  # Broadcast AFTER the transaction, so a subscriber that re-reads on the
  # message can only ever see committed state.
  defp announce(release) do
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(release.id), {:release_finished, release.id})
    release
  end

  @doc """
  Publish every pending item in `release`, atomically.

  Returns `{:ok, release}` with the release marked `:published`, or
  `{:error, reason}` with it marked `:failed` and nothing changed on the site.
  Expects the release to have been claimed already (state `:publishing` — see
  `ContentRelease`'s `:start`), which is what stops the minute cron from starting
  the same release twice.
  """
  @spec publish(struct()) :: {:ok, struct()} | {:error, term()}
  def publish(%{state: :publishing} = release) do
    actor = triggering_actor(release)
    opts = system_opts(release)
    items = pending_items(release, opts)

    case run_transaction(fn -> apply_all(release, items, actor, opts) end) do
      {:ok, {published, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, announce(published)}

      {:error, reason} ->
        announce(release)
        fail(release, items, reason, opts)
    end
  end

  def publish(%{state: state}), do: {:error, {:unexpected_state, state}}

  @doc """
  Undo a published release: restore every `:applied` item's prior published
  version and workflow state, in reverse order, in one transaction.

  `:skipped` items are left alone — the release didn't change them. Returns
  `{:ok, release}` with the release `:rolled_back`, or `{:error, reason}` with it
  returned to `:published` and nothing changed.
  """
  @spec roll_back(struct()) :: {:ok, struct()} | {:error, term()}
  def roll_back(%{state: :rolling_back} = release) do
    actor = triggering_actor(release)
    opts = system_opts(release)

    items =
      release
      |> applied_items(opts)
      |> Enum.reverse()

    case run_transaction(fn -> undo_all(release, items, actor, opts) end) do
      {:ok, {rolled_back, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, announce(rolled_back)}

      {:error, reason} ->
        {item_id, message} = describe_failure(reason, items)

        CMS.mark_release_rollback_failed(
          release,
          %{failure_reason: message, failed_item_id: item_id},
          opts
        )

        announce(release)
        {:error, reason}
    end
  end

  def roll_back(%{state: state}), do: {:error, {:unexpected_state, state}}

  @doc """
  What each of `release`'s pending items would do if it went live right now, as
  `{item, classification}` pairs.

  Read-only, and the same classifier the go-live transaction uses — so the
  console's readiness panel and the worker can never disagree about whether a
  release is publishable.
  """
  @spec readiness(struct(), keyword()) :: [{struct(), classification()}]
  def readiness(release, opts \\ []) do
    opts = readiness_opts(release, opts)
    items = pending_items(release, opts)
    records = resolve_records(items, opts)

    Enum.map(items, fn item -> {item, classify_resolved(item, Map.get(records, item.id))} end)
  end

  # A caller that supplies an actor gets AUTHORIZED reads. `Keyword.merge` alone
  # got this wrong: the caller never passes `:authorize?`, so `authorize?: false`
  # from `system_opts/1` always survived, and the console's readiness panel
  # reported the workflow state of content the reader's own policies hide.
  defp readiness_opts(release, opts) do
    if Keyword.has_key?(opts, :actor),
      do: Keyword.put_new(opts, :tenant, release.org_id),
      else: Keyword.merge(system_opts(release), opts)
  end

  # One read per content TYPE, not per item. The console recomputes readiness on
  # mount and after every click, so a fifty-post release was fifty queries a
  # render. The go-live transaction still reads each record individually — there
  # it needs the freshest possible row, one at a time, right before it writes.
  defp resolve_records(items, opts) do
    items
    |> Enum.group_by(& &1.content_type)
    |> Enum.flat_map(fn {type, rows} -> records_for_type(type, rows, opts) end)
    |> Map.new()
  end

  defp records_for_type(type, rows, opts) do
    ids = rows |> Enum.map(& &1.content_id) |> Enum.uniq()
    query = [filter: [id: [in: ids]], select: [:id, :state]]

    found =
      type
      |> ContentTypes.list!(Keyword.put(opts, :query, query))
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, &{&1.id, found[&1.content_id]})
  rescue
    # The content type was retired since the item was added.
    _error -> Enum.map(rows, &{&1.id, nil})
  end

  defp classify_resolved(_item, nil), do: {:error, "content no longer exists"}
  defp classify_resolved(item, record), do: classify_record(item, record)

  # --- go-live ---------------------------------------------------------------

  defp apply_all(release, items, actor, opts) do
    item_notes =
      Enum.reduce(items, [], fn item, acc ->
        case apply_item(item, actor, opts) do
          {:ok, notes} -> notes ++ acc
          {:error, reason} -> Repo.rollback({item.id, reason})
        end
      end)

    {published, release_notes} =
      case CMS.mark_release_published(release, %{}, notifying(opts)) do
        {:ok, published, notes} -> {published, notes}
        {:error, reason} -> Repo.rollback({nil, describe(reason)})
      end

    # Inside the transaction on purpose: the delivery ledger rows and Oban jobs
    # this creates must vanish with everything else if a later step aborts, and
    # nothing after this point can abort. Automation is dispatched off the same
    # funnel (`Webhooks.dispatch/3`), so a `release.published` rule fires here too.
    Webhooks.dispatch("release.published", event_payload(published, items), published.org_id)

    {published, release_notes ++ item_notes}
  end

  defp apply_item(item, actor, opts) do
    with {:ok, record} <- fetch_record(item, opts) do
      prior = %{state: record.state, version: Map.get(record, :published_version_id)}

      case classify_record(item, record) do
        :apply -> transition(item, record, prior, actor, opts)
        {:skip, _why} -> mark_skipped(item, prior, opts)
        {:error, _reason} = error -> error
      end
    end
  end

  defp transition(item, record, prior, actor, opts) do
    with {:ok, notes} <- run_transition(item.content_type, verb(item.action), record, actor, opts),
         {:ok, mark_notes} <- mark_applied(item, prior, opts) do
      {:ok, notes ++ mark_notes}
    end
  end

  defp mark_applied(item, prior, opts) do
    params = %{prior_state: prior.state, prior_version_id: prior.version}
    notified(CMS.mark_release_item_applied(item, params, notifying(opts)))
  end

  defp mark_skipped(item, prior, opts) do
    notified(CMS.mark_release_item_skipped(item, %{prior_state: prior.state}, notifying(opts)))
  end

  defp fail(release, items, reason, opts) do
    {item_id, message} = describe_failure(reason, items)

    Logger.error("Release #{release.id} go-live aborted: #{message}")

    CMS.mark_release_failed(
      release,
      %{failure_reason: message, failed_item_id: item_id},
      opts
    )

    {:error, reason}
  end

  # --- rollback --------------------------------------------------------------

  defp undo_all(release, items, actor, opts) do
    item_notes =
      Enum.reduce(items, [], fn item, acc ->
        case undo_item(item, actor, opts) do
          {:ok, notes} -> notes ++ acc
          {:error, reason} -> Repo.rollback({item.id, reason})
        end
      end)

    {rolled_back, release_notes} =
      case CMS.mark_release_rolled_back(release, %{}, notifying(opts)) do
        {:ok, rolled_back, notes} -> {rolled_back, notes}
        {:error, reason} -> Repo.rollback({nil, describe(reason)})
      end

    Webhooks.dispatch(
      "release.rolled_back",
      event_payload(rolled_back, items),
      rolled_back.org_id
    )

    {rolled_back, release_notes ++ item_notes}
  end

  # Rollback is driven by the item's captured PRIOR STATE, not by inverting its
  # action — that way one clause covers both a publish being undone and an
  # unpublish being undone, and the "put it back exactly as it was" contract is
  # written once.
  defp undo_item(item, actor, opts) do
    with {:ok, notes} <- undo_content(item, actor, opts),
         {:ok, mark_notes} <-
           notified(CMS.mark_release_item_rolled_back(item, %{}, notifying(opts))) do
      {:ok, notes ++ mark_notes}
    end
  end

  # Content that is gone has nothing to restore, so rollback records the item as
  # undone and moves on. Failing here instead would wedge the group permanently:
  # the release returns to `:published`, the item stays `:applied`, and every
  # retry hits the same deleted record — so one purged page would strand every
  # OTHER item of the release live, with no way to take the group down. Go-live
  # has the same shape of escape for an item whose desired state already holds.
  defp undo_content(item, actor, opts) do
    case fetch_record(item, opts) do
      {:ok, record} ->
        restore_state(item, record, actor, opts)

      {:error, _gone} ->
        Logger.warning(
          "Release item #{item.id} (#{item.content_type} #{item.content_id}) has no content " <>
            "to roll back; recording it as undone"
        )

        {:ok, []}
    end
  end

  # It was live before the release: put it back up, carrying the exact body that
  # was live. The restore matters for an item the release UNPUBLISHED — content
  # can be edited freely while it is dark, and republishing the drifted body
  # would be a different page than the one rollback promised to bring back.
  defp restore_state(%{prior_state: :published} = item, record, actor, opts) do
    with {:ok, restore_notes} <- maybe_restore_version(item, record, actor, opts),
         {:ok, reloaded} <- fetch_record(item, opts),
         {:ok, notes} <- republish(item, reloaded, actor, opts) do
      {:ok, restore_notes ++ notes}
    end
  end

  # It was NOT live before the release, so the release is what put it up: take it
  # back down, and return it to `:in_review` if that is where it was — an
  # unpublish always lands in `:draft`, which would quietly lose a review that
  # was in flight.
  defp restore_state(item, record, actor, opts) do
    with {:ok, down_notes} <- take_down(item, record, actor, opts),
         {:ok, reloaded} <- fetch_record(item, opts),
         {:ok, notes} <- restore_review(item, reloaded, actor, opts) do
      {:ok, down_notes ++ notes}
    end
  end

  defp republish(_item, %{state: :published}, _actor, _opts), do: {:ok, []}

  defp republish(item, record, actor, opts),
    do: run_transition(item.content_type, "publish", record, actor, opts)

  defp restore_review(%{prior_state: :in_review} = item, %{state: :draft} = record, actor, opts),
    do: run_transition(item.content_type, "submit", record, actor, opts)

  defp restore_review(_item, _record, _actor, _opts), do: {:ok, []}

  defp take_down(item, %{state: :published} = record, actor, opts),
    do: run_transition(item.content_type, "unpublish", record, actor, opts)

  defp take_down(_item, _record, _actor, _opts), do: {:ok, []}

  defp maybe_restore_version(%{prior_version_id: nil}, _record, _actor, _opts), do: {:ok, []}

  defp maybe_restore_version(%{prior_version_id: version_id} = item, record, actor, opts) do
    if drifted?(item, record) do
      notified(
        ContentTypes.restore_version(item.content_type, record, version_id, acting(opts, actor))
      )
    else
      {:ok, []}
    end
  end

  # Only reconstruct the prior body when the record actually changed after the
  # release touched it. Republishing an untouched record already yields exactly
  # the body that was live, and a needless restore is not free: it cuts another
  # version, re-fires the artifacts, and — for content whose history predates
  # version tracking — can legitimately fail to reconstruct required fields,
  # which would abort a rollback that had nothing to reconstruct in the first
  # place. A missing `applied_at` (an item written before this field existed)
  # reads as drifted, i.e. restore rather than assume.
  defp drifted?(%{applied_at: nil}, _record), do: true

  defp drifted?(%{applied_at: applied_at}, %{updated_at: updated_at}),
    do: DateTime.compare(updated_at, applied_at) == :gt

  defp drifted?(_item, _record), do: true

  defp run_transition(content_type, verb, record, actor, opts),
    do: notified(ContentTypes.transition(content_type, verb, record, acting(opts, actor)))

  # --- classification --------------------------------------------------------

  @doc """
  What one item would do right now: apply, skip (already true), or fail.
  """
  @spec classify(struct(), keyword()) :: classification()
  def classify(item, opts) do
    case fetch_record(item, opts) do
      {:ok, record} -> classify_record(item, record)
      {:error, reason} -> {:error, reason}
    end
  end

  # Publishing something already live, or taking down something already down, is
  # a no-op — the release's desired end state holds either way.
  defp classify_record(%{action: :publish}, %{state: :published}),
    do: {:skip, :already_in_state}

  defp classify_record(%{action: :unpublish}, %{state: state}) when state != :published,
    do: {:skip, :already_in_state}

  defp classify_record(%{action: :publish}, %{state: state})
       when state not in [:draft, :in_review] do
    {:error, "cannot be published from #{state}"}
  end

  defp classify_record(_item, _record), do: :apply

  # --- shared helpers --------------------------------------------------------

  defp pending_items(release, opts),
    do: CMS.list_release_items_with_status!(release.id, :pending, opts)

  defp applied_items(release, opts),
    do: CMS.list_release_items_with_status!(release.id, :applied, opts)

  # `get_record/3` raises for a content type that no longer exists (a dynamic
  # type deleted after the item was added), and returns an error for a record
  # that was trashed or purged. Both are real reasons a release can't ship, and
  # both must read as an error rather than as an exception escaping a transaction.
  defp fetch_record(item, opts) do
    case ContentTypes.get_record(item.content_type, item.content_id, opts) do
      {:ok, record} -> {:ok, record}
      {:error, _reason} -> {:error, "content no longer exists"}
    end
  rescue
    _error -> {:error, "unknown content type #{item.content_type}"}
  end

  defp verb(:publish), do: "publish"
  defp verb(:unpublish), do: "unpublish"

  # Ash DROPS a resource's notifications (PubSub, GraphQL subscriptions, the
  # console's live updates) when the action runs inside a transaction it did not
  # open — it can't publish an event for a write that might still roll back. Every
  # write here is in exactly that position, so each one asks for its notifications
  # back and the caller replays them with `Ash.Notifier.notify/1` after the commit.
  # Without this the site would go live and nothing subscribed would hear about it.
  defp notifying(opts), do: Keyword.put(opts, :return_notifications?, true)

  defp acting(opts, actor), do: opts |> notifying() |> Keyword.put(:actor, actor)

  defp notified({:ok, _record, notifications}), do: {:ok, notifications}
  defp notified({:ok, _record}), do: {:ok, []}
  defp notified({:error, reason}), do: {:error, describe(reason)}

  # Every write here runs unauthorized on purpose: the authorization decision was
  # made when an admin claimed the release (`:start` / `:start_rollback` are
  # admin-only), and the worker publishes types the claiming admin may not hold
  # individually. `triggering_actor/1` is what keeps the writes attributable.
  defp system_opts(release), do: [authorize?: false, tenant: release.org_id]

  defp triggering_actor(%{triggered_by_id: nil}), do: nil

  # Users are global, not org-partitioned — no tenant here.
  defp triggering_actor(%{triggered_by_id: id}) do
    case KilnCMS.Accounts.get_user(id, authorize?: false) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp run_transaction(fun) do
    Repo.transaction(fun, timeout: @transaction_timeout_ms)
  end

  defp event_payload(release, items) do
    %{
      "id" => release.id,
      "name" => release.name,
      "state" => to_string(release.state),
      "published_at" => release.published_at && DateTime.to_iso8601(release.published_at),
      "items" =>
        Enum.map(items, fn item ->
          %{
            "type" => item.content_type,
            "id" => item.content_id,
            "action" => to_string(item.action)
          }
        end)
    }
  end

  # Two shapes reach us. Our own `Repo.rollback({item_id, message})` carries the
  # item outright. But an Ash action that fails INSIDE an existing transaction
  # rolls the transaction back itself (`Ash.Actions.Helpers.rollback_if_in_transaction`),
  # so the term is Ash's changeset for the content record that failed — from
  # which the item is recoverable by id. Anything else degrades to "no item".
  defp describe_failure({item_id, message}, _items) when is_binary(message),
    do: {item_id, message}

  defp describe_failure(%Ash.Changeset{data: %{id: content_id}} = changeset, items) do
    item = Enum.find(items, &(&1.content_id == content_id))
    {item && item.id, describe(changeset)}
  end

  defp describe_failure(other, _items), do: {nil, describe(other)}

  # Ash error breakdowns are multi-line and can be long; `failure_reason` is a
  # console field, not a log.
  @reason_limit 500

  defp describe(%Ash.Changeset{errors: errors}) when errors != [],
    do: errors |> Ash.Error.to_error_class() |> describe()

  defp describe(reason) when is_binary(reason), do: String.slice(reason, 0, @reason_limit)

  defp describe(reason) when is_exception(reason),
    do: reason |> Exception.message() |> String.slice(0, @reason_limit)

  defp describe(reason), do: reason |> inspect() |> String.slice(0, @reason_limit)
end
