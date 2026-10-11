defmodule KilnCMS.CMS.Changes.NotifySubscribersWithdrawn do
  @moduledoc """
  After a content action takes a published record out of delivery, tell the
  `<type>Changed` GraphQL subscribers it is gone, as `destroyed` (#1925).

  Attach beside `NotifyWebhooks event: "unpublished"`, with the same
  `only_when:`:

      change {KilnCMS.CMS.Changes.NotifySubscribersWithdrawn, only_when: :was_published}

  ## Why a retraction needs its own notification

  Unpublishing and archiving are `:update` actions. ash_graphql resolves an
  update **per subscriber, through the policy-scoped read**: it re-reads the
  record as that subscriber and sends what the read returns. That is what
  keeps drafts out of an anonymous feed. It is also why a retraction never
  arrives: once the record has left `:published`, the anonymous read answers
  not found, and `AshGraphql.Subscription.Batcher.should_send?/1` drops
  not-found results rather than leak that a record exists. The one event a
  public reader most needs is the one the model cannot deliver.

  `destroyed` is the only arm of the subscription union that carries an id
  without reading the record, so it is the honest shape for "this left your
  feed". The contract this sets, documented in the GraphQL guide: in a
  `<type>Changed` subscription, `destroyed` means the record is no longer in
  the published feed, whether it was unpublished, archived or deleted. A
  bearer-authed editor also receives the `updated` push for the same
  transition, since the record is still readable to them.

  Runs `after_transaction`, like `NotifyWebhooks`: a notification of a write
  that has already committed, which must not be able to undo it. It publishes
  the same `AshGraphql.Subscription.Batcher.Notification` the resource's own
  `AshGraphql.Subscription.Notifier` would for a real `:destroy`, to the same
  pubsub and topic, so the batcher, tenant guard and relay-id encoding all
  apply unchanged.
  """
  use Ash.Resource.Change

  alias AshGraphql.Resource.Info
  alias AshGraphql.Subscription.Batcher.Notification

  @impl true
  def change(changeset, opts, _context) do
    only_when = Keyword.get(opts, :only_when)

    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, record} ->
        if withdrawn?(only_when, changeset), do: publish(changeset, record)
        {:ok, record}

      _changeset, other ->
        other
    end)
  end

  # `changeset.data` is the record BEFORE the action: a retraction is only a
  # retraction if there was a live record to retract. The same check as
  # `NotifyWebhooks`' `:was_published`, for the same reason — `:archive` lands
  # on `:archived` from any state, and archiving a draft withdrew nothing.
  defp withdrawn?(nil, _changeset), do: true
  defp withdrawn?(:was_published, changeset), do: changeset.data.state == :published

  defp publish(changeset, %resource{} = record) do
    domain = KilnCMS.CMS
    pubsub = Info.subscription_pubsub(resource, domain)

    for subscription <- Info.subscriptions(resource, domain),
        :destroy in List.wrap(subscription.action_types) do
      Absinthe.Subscription.publish(
        pubsub,
        %Notification{
          action_type: :destroy,
          data: record,
          # What `AshGraphql.Subscription.Notifier` sends, so the resolver's
          # tenant guard treats this like the write's own notification.
          tenant: changeset.tenant || record.org_id
        },
        [{subscription.name, "*"}]
      )
    end

    :ok
  end
end
