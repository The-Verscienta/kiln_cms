defmodule KilnCMS.Billing.Webhooks do
  @moduledoc """
  Resolving a verified provider event to the membership it concerns.

  ## Never from the request host

  `KilnCMSWeb.Plugs.SetTenant` resolves the Ash tenant from `conn.host` and falls
  back to the **default org** for an unknown host. A provider webhook arrives at
  whatever host is configured in the provider's dashboard, so the ambient tenant on
  that request is meaningless and quite possibly wrong. Everything here resolves
  the organization from the **event**, and every write is then explicitly scoped to
  the found row's own `org_id` — the same handshake
  `KilnCMSWeb.NewsletterController` uses for token-authenticated public writes.

  ## The resolution ladder

  1. **Metadata** — `membership_id` (and `org_id`) stamped onto the checkout
     session *and* onto `subscription_data`, so both the session event and every
     later subscription event are self-describing. Checkout-session metadata does
     **not** propagate to the subscription object, which is why both are stamped.
     The loaded row is verified against the metadata: a signature-verified event
     whose metadata disagrees with our own record is a bug or an attack, so it is
     refused rather than written.
  2. **Subscription id** — `multitenancy :bypass` lookup, the sanctioned strict-
     tenancy exception.
  3. **Customer id** — may match several rows if the customer holds more than one
     tier, so it is disambiguated by the event's price id. Still ambiguous means
     ignored, never guessed.
  4. Nothing resolves → `{:ignored, :unresolvable}`, which the receiver acks with a
     200. That is normal steady state: events for a customer created outside Kiln,
     or after a membership row was scrubbed. A 500 here would make the provider
     retry for days and eventually disable the endpoint.
  """
  require Logger

  alias KilnCMS.Billing

  @doc """
  Find the membership a verified event concerns.

  Returns `{:ok, membership}`, or `{:ignored, reason}` when the event does not
  correspond to anything we hold.
  """
  @spec resolve(map()) :: {:ok, struct()} | {:ignored, atom()}
  def resolve(event) do
    object = object(event)

    with {:ignored, _reason} <- by_metadata(object),
         {:ignored, _reason} <- by_subscription(object),
         {:ignored, _reason} <- by_customer(object) do
      {:ignored, :unresolvable}
    end
  end

  @doc """
  The organization an event belongs to, if it can be determined.

  Used by the receiver purely to stamp the audit row; resolution for *writes* goes
  through `resolve/1`, which verifies against the stored membership.
  """
  @spec org_id(map()) :: Ash.UUID.t() | nil
  def org_id(event) do
    case resolve(event) do
      {:ok, membership} -> membership.org_id
      {:ignored, _reason} -> event |> object() |> metadata() |> Map.get("org_id")
    end
  end

  defp by_metadata(object) do
    metadata = metadata(object)

    case {metadata["membership_id"], metadata["org_id"]} do
      {nil, _org_id} ->
        {:ignored, :no_metadata}

      {membership_id, org_id} ->
        fetch_and_verify(membership_id, org_id, metadata)
    end
  end

  defp fetch_and_verify(membership_id, org_id, metadata) do
    # `org_id` from metadata is only a hint for the tenant of this read; the row's
    # own `org_id` is what every subsequent write uses.
    tenant = org_id || KilnCMS.Accounts.default_org_id()

    case Billing.get_membership(membership_id,
           authorize?: false,
           tenant: tenant,
           not_found_error?: false
         ) do
      {:ok, nil} ->
        {:ignored, :membership_not_found}

      {:ok, membership} ->
        verify(membership, org_id, metadata)

      {:error, _reason} ->
        {:ignored, :membership_not_found}
    end
  end

  # A signature-verified event whose metadata contradicts our own row means
  # something is wrong upstream. Refuse rather than write.
  defp verify(membership, org_id, metadata) do
    user_id = metadata["user_id"]

    cond do
      org_id && membership.org_id != org_id ->
        Logger.warning(
          "billing: event metadata org #{inspect(org_id)} disagrees with membership " <>
            "#{membership.id} (#{membership.org_id}); refusing."
        )

        {:ignored, :metadata_mismatch}

      user_id && membership.user_id != user_id ->
        Logger.warning(
          "billing: event metadata user #{inspect(user_id)} disagrees with membership " <>
            "#{membership.id}; refusing."
        )

        {:ignored, :metadata_mismatch}

      true ->
        {:ok, membership}
    end
  end

  defp by_subscription(object) do
    case subscription_id(object) do
      nil ->
        {:ignored, :no_subscription_id}

      subscription_id ->
        case Billing.membership_by_subscription(subscription_id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, nil} -> {:ignored, :no_membership_for_subscription}
          {:ok, membership} -> {:ok, membership}
          {:error, _reason} -> {:ignored, :no_membership_for_subscription}
        end
    end
  end

  defp by_customer(object) do
    with customer_id when is_binary(customer_id) <- customer_id(object),
         {:ok, memberships} <-
           Billing.memberships_by_customer(customer_id, authorize?: false) do
      disambiguate(memberships, object)
    else
      _other -> {:ignored, :no_membership_for_customer}
    end
  end

  defp disambiguate([], _object), do: {:ignored, :no_membership_for_customer}
  defp disambiguate([membership], _object), do: {:ok, membership}

  defp disambiguate(memberships, object) do
    # More than one tier for the same customer: pick by the event's price id, and
    # if that still doesn't single one out, refuse rather than guess.
    with price_id when is_binary(price_id) <- price_id(object),
         {:ok, tier} <-
           Billing.tier_by_price(price_id, authorize?: false, not_found_error?: false),
         false <- is_nil(tier),
         [membership] <- Enum.filter(memberships, &(&1.tier_id == tier.id)) do
      {:ok, membership}
    else
      _other ->
        Logger.warning(
          "billing: #{length(memberships)} memberships match this customer and the " <>
            "event does not single one out; ignoring."
        )

        {:ignored, :ambiguous_customer}
    end
  end

  defp object(%{"data" => %{"object" => object}}) when is_map(object), do: object
  defp object(_event), do: %{}

  defp metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp metadata(_object), do: %{}

  defp subscription_id(%{"object" => "subscription", "id" => id}) when is_binary(id), do: id
  defp subscription_id(%{"subscription" => %{"id" => id}}), do: id
  defp subscription_id(%{"subscription" => id}) when is_binary(id), do: id
  defp subscription_id(_object), do: nil

  defp customer_id(%{"customer" => %{"id" => id}}), do: id
  defp customer_id(%{"customer" => id}) when is_binary(id), do: id
  defp customer_id(_object), do: nil

  # The price id lives in different places depending on the event shape.
  defp price_id(%{"items" => %{"data" => [%{"price" => %{"id" => id}} | _rest]}}), do: id
  defp price_id(%{"lines" => %{"data" => [%{"price" => %{"id" => id}} | _rest]}}), do: id
  defp price_id(%{"plan" => %{"id" => id}}), do: id
  defp price_id(_object), do: nil
end
