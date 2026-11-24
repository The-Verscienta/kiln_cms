defmodule KilnCMS.Billing.EventGuard do
  @moduledoc """
  Whether a provider event may be applied to the membership it resolved to
  (#2749). Pure: the same function decides in `KilnCMS.Billing.Subscriptions`
  before the write and in `KilnCMS.Billing.Changes.GuardProviderEvent` under the
  row lock, so the two cannot disagree about what a "stale" event is.

  Metadata resolves an event to a membership *row*, not to a *subscription*. One
  row can see two subscriptions over its life (checkout abandoned, retried and
  paid), and the provider delivers late and retries, so two things are checked.

  ## Subscription identity

    * A `:comped` row is not provider-managed: every provider event is ignored
      (`:comped_not_provider_managed`). Comping a paying member does not cancel
      the provider subscription (#3156).
    * An entitling row that holds a provider subscription id ignores an event
      about a different one (`:other_subscription`). A row that does not entitle
      accepts a different subscription only when it is `:incomplete` (an
      abandoned checkout replaced by a paid one), when the state was retrieved
      live at checkout (a canceled member resubscribing), or when the event is
      strictly newer than the last one applied. A late non-terminal event for
      the old subscription of a `:canceled` row is ignored.
    * An event with **no** subscription id on an entitling row **fails open**:
      it was resolved by metadata or customer, and there is nothing to compare.
    * A terminal (`:canceled`) event for a subscription other than the stored one
      is ignored on every row, so it never overwrites the stored id and never
      cancels a subscription the row does not hold. With no stored id on a row
      that does not entitle there is nothing to cancel and no way to tell
      whether the event is stale; an entitling row with no stored id fails open
      as above.

  ## Ordering

  Per subscription: an event is compared with the row's
  `last_provider_event_at` only when it is about the stored subscription, or the
  row has none. A different subscription that the identity rules admit starts
  afresh, so on an `:incomplete` row `deleted(A)` at T2 followed by a delayed
  `active(B)` created at T1 < T2 still activates B.

    * strictly older than the stamp: `:out_of_order`;
    * equal (one-second resolution) applies, except that a non-terminal event
      never revives a `:canceled` row at an equal stamp. The residual window is
      two *different* events in the same second, in the wrong order;
    * a state retrieved live (`:live`) is exempt. It is stamped with the
      checkout event's own `created` (the provider's clock, the same one later
      events carry), never the local clock. A replayed checkout older than the
      stamp leaves the stamp where it was
      (`KilnCMS.Billing.Changes.GuardProviderEvent`, #3159);
    * an event with no usable `created` is accepted (the caller logs it).
  """

  alias KilnCMS.Billing.Membership

  # Both are plain `map()` in the spec: callers hand over a `Membership` struct
  # (typed `struct()` where it is read back from the action), and a precise map
  # type with required keys makes Dialyzer reject that call. The fields read are
  # `status`, `provider_subscription_id` and `last_provider_event_at` on the
  # row, and `kind`, `subscription_id`, `created_at` and `target_status` on the
  # event.
  @typedoc "The row fields the decision reads."
  @type row :: map()

  @typedoc "What the event says about itself."
  @type event :: map()

  @spec check(row(), event()) :: :ok | {:ignore, atom()}
  def check(%{status: :comped}, _event), do: {:ignore, :comped_not_provider_managed}

  def check(row, event) do
    cond do
      other_subscription?(row, event) -> {:ignore, :other_subscription}
      stale?(row, event) -> {:ignore, :out_of_order}
      true -> :ok
    end
  end

  defp other_subscription?(row, %{subscription_id: event_id, target_status: target} = event) do
    stored = row.provider_subscription_id

    cond do
      # Fails open: nothing to compare.
      is_nil(event_id) -> false
      stored == event_id -> false
      # A terminal event for a subscription we do not hold: ignored whatever
      # the row's status, so it never rewrites the stored id. An entitling row
      # with no stored id has nothing to compare, so it fails open like above.
      target == :canceled -> not (is_nil(stored) and Membership.entitling?(row.status))
      Membership.entitling?(row.status) -> not is_nil(stored)
      true -> not replaces_dead_subscription?(row, event)
    end
  end

  # A row that does not entitle holds a subscription that is over (or never
  # paid). A different subscription may take it over only if it is plausibly a
  # new one: the row never got going (`:incomplete`, an abandoned checkout), the
  # state was just retrieved live (a resubscription at checkout), or the event is
  # strictly newer than the last one applied. A late non-terminal event for the
  # old subscription would otherwise revive access on a dead one.
  defp replaces_dead_subscription?(%{provider_subscription_id: nil}, _event), do: true
  defp replaces_dead_subscription?(_row, %{kind: :live}), do: true
  defp replaces_dead_subscription?(%{status: :incomplete}, _event), do: true
  defp replaces_dead_subscription?(%{last_provider_event_at: nil}, _event), do: false
  defp replaces_dead_subscription?(_row, %{created_at: nil}), do: false

  defp replaces_dead_subscription?(row, event),
    do: DateTime.compare(event.created_at, row.last_provider_event_at) == :gt

  defp stale?(_row, %{kind: :live}), do: false
  defp stale?(_row, %{created_at: nil}), do: false
  defp stale?(%{last_provider_event_at: nil}, _event), do: false

  defp stale?(row, event) do
    if same_subscription?(row, event) do
      case DateTime.compare(event.created_at, row.last_provider_event_at) do
        :lt -> true
        :eq -> row.status == :canceled and event.target_status != :canceled
        :gt -> false
      end
    else
      false
    end
  end

  @doc """
  Whether the event is ordered against the row's `last_provider_event_at`: it
  is about the stored subscription, or either side names none. A different
  subscription starts its own ordering.
  """
  @spec same_subscription?(row(), event()) :: boolean()
  def same_subscription?(%{provider_subscription_id: nil}, _event), do: true
  def same_subscription?(_row, %{subscription_id: nil}), do: true
  def same_subscription?(row, event), do: row.provider_subscription_id == event.subscription_id
end
