defmodule KilnCMS.Billing.Subscriptions do
  @moduledoc """
  Provider event → membership transition.

  ## The one rule

  **The audience follows the mapped status, and the status follows the provider.**
  Everything the acceptance criteria ask for falls out of that:

    * *Pay and read immediately* — `checkout.session.completed` retrieves the
      subscription and applies its status in the same pass, so the happy path
      activates on one event instead of waiting for a follow-up.
    * *Cancellation revokes at period end without admin involvement* — with
      `cancel_at_period_end`, the provider keeps `status: "active"` for the whole
      paid period and fires `customer.subscription.deleted` when it lapses. So
      following the provider's status *is* "revoke at period end", with **no local
      timer**. `current_period_end` is stored for display only; a second clock here
      would mean two sources of truth.
    * *Immediate cancellation* revokes at once, because the provider says
      `deleted` at once.

  ## Handled events

  Four, allowlisted; everything else is acked and ignored so a
  misconfigured provider endpoint sending forty event types cannot fill the table.

  | Event | Effect |
  |---|---|
  | `checkout.session.completed` | store provider ids, then apply the retrieved subscription's status |
  | `customer.subscription.updated` | the workhorse: renewals, dunning, cancel-at-period-end flips, reactivations |
  | `customer.subscription.deleted` | terminal `:canceled` |
  | `invoice.payment_failed` | `:past_due`, and **only** from `:active` |

  `invoice.payment_failed` is belt, not authority: `customer.subscription.updated`
  is the authoritative source, and handling both without the from-`:active` guard
  would let a late-arriving invoice event demote a subscription the member has
  already fixed.

  ## Late, retried and foreign events (#2749)

  Metadata resolves an event to a membership row, not to a subscription, and the
  provider delivers late and retries. Before anything is written,
  `KilnCMS.Billing.EventGuard` ignores an event that is older than the last one
  applied to the same subscription (`:out_of_order`), one about a different
  subscription than a paying row holds (`:other_subscription`, logged at
  warning), a different subscription taking over a dead row without being
  newer, and any event for a `:comped` row (logged at warning: an operator who
  comped a member who was paying cancels the provider subscription in the
  provider's dashboard, #3156). The row stores the provider's
  `created` stamp (`last_provider_event_at`); a state retrieved at checkout is
  newer than any event and is stamped with the checkout event's own `created` instead. The
  action repeats the check under the row lock
  (`KilnCMS.Billing.Changes.GuardProviderEvent`). Ignored events are acked.

  Deliberately unhandled: `invoice.paid` / `invoice.payment_succeeded` (a renewal
  already arrives as `subscription.updated` carrying the new period) and
  `customer.subscription.created` (checkout's completion plus the retrieve covers
  it).
  """
  require Logger

  alias KilnCMS.Billing
  alias KilnCMS.Billing.EventGuard

  @handled ~w(
    checkout.session.completed
    customer.subscription.updated
    customer.subscription.deleted
    invoice.payment_failed
  )

  # Provider subscription status → local membership status.
  @status_map %{
    "trialing" => :active,
    "active" => :active,
    "past_due" => :past_due,
    # Dunning is exhausted — keeping access here would be indefinite free service.
    "unpaid" => :canceled,
    "incomplete" => :incomplete,
    "incomplete_expired" => :canceled,
    "canceled" => :canceled,
    # A paused subscription is not being paid for.
    "paused" => :canceled
  }

  @doc "The event types this module acts on; everything else is ignored."
  @spec handled_types() :: [String.t()]
  def handled_types, do: @handled

  @doc "Whether `type` is one of the handled event types."
  @spec handled?(String.t()) :: boolean()
  def handled?(type), do: type in @handled

  @doc "Map a provider subscription status onto a membership status."
  @spec membership_status(String.t()) :: atom() | nil
  def membership_status(provider_status), do: Map.get(@status_map, provider_status)

  @doc """
  Apply a verified event to its membership.

  Returns `{:ok, membership}` when state was applied, `{:ignored, reason}` when the
  event is not actionable (an unhandled type, a non-subscription checkout, an
  unresolvable membership), or `{:error, reason}` for a transient failure the
  caller should retry.
  """
  @spec apply(map()) ::
          {:ok, struct()} | {:ignored, atom() | String.t()} | {:error, term()}
  def apply(%{"type" => type} = event) do
    if handled?(type), do: dispatch(type, event), else: {:ignored, :unhandled_type}
  end

  def apply(_event), do: {:ignored, :malformed_event}

  defp dispatch("checkout.session.completed", event) do
    session = object(event)

    # Only subscription checkouts create memberships; a one-off payment mode is
    # not something this feature sells.
    if session["mode"] == "subscription" do
      complete_checkout(session, event)
    else
      {:ignored, :not_a_subscription}
    end
  end

  defp dispatch("customer.subscription.deleted", event) do
    subscription = object(event)

    with {:ok, membership} <- Billing.Webhooks.resolve(event) do
      apply_state(
        membership,
        %{
          status: :canceled,
          provider_subscription_id: subscription["id"],
          cancel_at_period_end: false
        },
        event
      )
    end
  end

  defp dispatch("customer.subscription.updated", event) do
    subscription = object(event)

    with {:ok, membership} <- Billing.Webhooks.resolve(event),
         {:ok, status} <- status_of(subscription) do
      apply_state(
        membership,
        %{
          status: status,
          provider_subscription_id: subscription["id"],
          provider_customer_id: customer_id(subscription),
          current_period_end: period_end(subscription),
          cancel_at_period_end: !!subscription["cancel_at_period_end"]
        },
        event
      )
    end
  end

  defp dispatch("invoice.payment_failed", event) do
    with {:ok, membership} <- Billing.Webhooks.resolve(event) do
      # Only ever a demotion from :active. `customer.subscription.updated` is the
      # authority; without this guard a late invoice event could demote a
      # subscription the member already repaired.
      if membership.status == :active do
        apply_state(membership, %{status: :past_due}, event)
      else
        {:ignored, :not_active}
      end
    end
  end

  # Checkout completion carries the ids but not a usable status, so retrieve the
  # subscription and apply what the provider actually says. One extra API call
  # buys a one-event happy path.
  defp complete_checkout(session, event) do
    with {:ok, membership} <- Billing.Webhooks.resolve(event),
         subscription_id = subscription_id(session),
         {:ok, subscription} <- retrieve(subscription_id),
         {:ok, status} <- status_of(subscription) do
      apply_state(
        membership,
        %{
          status: status,
          provider_customer_id: session["customer"] || customer_id(subscription),
          provider_subscription_id: subscription_id,
          current_period_end: period_end(subscription),
          cancel_at_period_end: !!subscription["cancel_at_period_end"]
        },
        event,
        :live
      )
    end
  end

  defp retrieve(nil), do: {:ignored, :no_subscription_on_session}

  defp retrieve(subscription_id) do
    with {:ok, config} <- Billing.credentials() do
      Billing.provider().retrieve_subscription(subscription_id, config)
    end
  end

  # `kind` is `:event` for a delivered event and `:live` for a state retrieved
  # from the provider just now (checkout completion): that is newer than any
  # event, so it is exempt from the stale check and stamped with the retrieval
  # time instead of the session's `created`.
  defp apply_state(membership, attrs, event, kind \\ :event) do
    target = %{
      kind: kind,
      subscription_id: event_subscription_id(event),
      created_at: created_at(event),
      target_status: attrs.status
    }

    with :ok <- check(membership, target, event) do
      attrs = Map.put(attrs, :provider_event_id, event["id"])

      # As the billing system actor (#1659): `Membership` closes
      # `:apply_provider_state` to every person and admits this actor by name.
      # A refusal is an `{:error, _}`, which the worker records and retries.
      #
      # The action repeats the check under the row lock
      # (`Changes.GuardProviderEvent`) and reports a superseded event as
      # metadata on the row it returns.
      membership
      |> Billing.apply_provider_state(
        attrs
        |> put_stamp(stamp(target))
        |> Map.put(:event_kind, kind)
        |> Map.put(:event_subscription_id, target.subscription_id)
        |> Map.put(:event_created_at, target.created_at),
        actor: Billing.system(),
        tenant: membership.org_id
      )
      |> ignored_or_ok()
    end
  end

  defp check(membership, target, event) do
    if target.kind == :event and is_nil(target.created_at) do
      Logger.warning(
        "billing: event #{inspect(event["id"])} carries no usable `created`; " <>
          "applying it without an ordering check."
      )
    end

    case EventGuard.check(membership, target) do
      :ok ->
        :ok

      {:ignore, :other_subscription = reason} ->
        # An operator signal: the provider is still billing a subscription this
        # membership does not hold, or an event arrived for an abandoned one.
        Logger.warning(
          "billing: ignoring #{inspect(event["type"])} #{inspect(event["id"])} for " <>
            "subscription #{inspect(target.subscription_id)}; membership #{membership.id} " <>
            "holds #{inspect(membership.provider_subscription_id)}."
        )

        {:ignored, reason}

      {:ignore, :comped_not_provider_managed = reason} ->
        # The provider may still be billing this member. Comping a paying member
        # does not cancel their subscription (#3156): the operator cancels it in
        # the provider's dashboard.
        Logger.warning(
          "billing: ignoring #{inspect(event["type"])} #{inspect(event["id"])} for " <>
            "subscription #{inspect(target.subscription_id)}: membership #{membership.id} " <>
            "is comped and not provider-managed."
        )

        {:ignored, reason}

      {:ignore, reason} ->
        {:ignored, reason}
    end
  end

  # An event with no usable `created` leaves the stamp where it was.
  defp put_stamp(attrs, nil), do: attrs
  defp put_stamp(attrs, stamp), do: Map.put(attrs, :last_provider_event_at, stamp)

  # Both clocks the stamp is later compared with are the provider's, in whole
  # seconds. A retrieved state is stamped with the checkout event's `created`;
  # the local clock (microseconds, possibly ahead) would make a same-second
  # later event look older and drop it, a `canceled` among them. Without a
  # `created`, now truncated to the second is the best available.
  defp stamp(%{kind: :live, created_at: nil}), do: DateTime.truncate(DateTime.utc_now(), :second)
  defp stamp(%{created_at: nil}), do: nil
  defp stamp(%{created_at: created_at}), do: created_at

  defp ignored_or_ok({:ok, membership}) do
    case Ash.Resource.get_metadata(membership, :event_ignored) do
      nil -> {:ok, membership}
      reason -> {:ignored, reason}
    end
  end

  defp ignored_or_ok(other), do: other

  # The event's own `created`, in seconds. Missing or not an integer: `nil`,
  # accepted without an ordering check.
  defp created_at(%{"created" => seconds}) when is_integer(seconds) and seconds >= 0,
    do: DateTime.from_unix!(seconds)

  defp created_at(_event), do: nil

  # The subscription an event is about. `invoice.payment_failed` carries it on
  # the invoice: at `parent.subscription_details.subscription` on the pinned
  # `2025-04-30.basil` API, at `subscription` before it.
  defp event_subscription_id(%{"type" => "customer.subscription." <> _} = event),
    do: id_of(object(event)["id"])

  defp event_subscription_id(event) do
    case object(event) do
      %{"parent" => %{"subscription_details" => %{"subscription" => sub}}} -> id_of(sub)
      %{"subscription" => sub} -> id_of(sub)
      _object -> nil
    end
  end

  defp id_of(id) when is_binary(id), do: id
  defp id_of(%{"id" => id}) when is_binary(id), do: id
  defp id_of(_other), do: nil

  defp status_of(%{"status" => provider_status}) do
    case membership_status(provider_status) do
      nil ->
        Logger.warning(
          "billing: unknown provider subscription status #{inspect(provider_status)}"
        )

        {:ignored, :unknown_status}

      status ->
        {:ok, status}
    end
  end

  defp status_of(_subscription), do: {:ignored, :no_status}

  defp object(%{"data" => %{"object" => object}}) when is_map(object), do: object
  defp object(_event), do: %{}

  # `subscription` is an id when unexpanded and an object when expanded.
  defp subscription_id(%{"subscription" => %{"id" => id}}), do: id
  defp subscription_id(%{"subscription" => id}) when is_binary(id), do: id
  defp subscription_id(_session), do: nil

  defp customer_id(%{"customer" => %{"id" => id}}), do: id
  defp customer_id(%{"customer" => id}) when is_binary(id), do: id
  defp customer_id(_subscription), do: nil

  # Stripe moved the period end onto each subscription item; accept both shapes so
  # a version bump can't silently null the member's renewal date.
  defp period_end(%{"current_period_end" => seconds}) when is_integer(seconds),
    do: DateTime.from_unix!(seconds)

  defp period_end(%{"items" => %{"data" => [%{"current_period_end" => seconds} | _rest]}})
       when is_integer(seconds),
       do: DateTime.from_unix!(seconds)

  defp period_end(_subscription), do: nil
end
