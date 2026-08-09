defmodule KilnCMS.Push do
  @moduledoc """
  Web Push notifications for the review queue (#628).

  The editor PWA (#65) installs to a phone home screen but could not tell a
  reviewer that something was waiting — push was one of the two capabilities
  `docs/mobile-admin-spike.md` §5.1 named as a real reason to prefer a native
  app. This closes that without a native toolchain.

  Three parts: `KilnCMS.Push.Vapid` identifies this deployment to the push
  service, `KilnCMS.Push.Encryption` encrypts the payload so the push service
  cannot read it, and `KilnCMS.Push.Worker` does one delivery per subscription
  with Oban's retries.

  ## Off unless configured

  No VAPID keys ⇒ `enabled?/0` is false, the settings page never offers the
  toggle, and `notify/2` returns `:ok` having done nothing. Same posture as
  service-worker registration: degrade silently where the capability is absent,
  because a deployment that has not opted into a third-party push service
  should not be nagged about it.

  ## What a notification is allowed to say

  **Never draft content.** The push service (Google, Mozilla, Apple) routes the
  message, and while the payload is encrypted end-to-end, the whole point of
  the constraint is not to depend on that being true forever, or on the browser
  vendor's storage of the decrypted notification. So a notification says that
  *something* is waiting and what kind of thing it is — never a title, an
  excerpt, an id or a slug, and the deep link is the filtered queue
  (`/editor?status=in_review`) rather than the document.

  The content **type** name is included deliberately: it tells a reviewer
  whether this is worth unlocking their phone for, and a type name is site
  structure that the public site's own URLs already publish. Nothing else about
  the document travels.

  ## Delivery goes through SafeFetch

  A push endpoint is a URL a *browser* chose and we POST to it, which makes it
  the same class of hazard as an oEmbed target: a hostile client could register
  an endpoint pointing at `169.254.169.254` or an internal host and use this
  server as a proxy. `KilnCMS.SafeFetch` resolves once, refuses private
  addresses and connects to the literal, so a DNS rebind between check and
  connect cannot land.

  ## Pruning

  A push service answers `404` or `410` for a subscription the browser has
  discarded (permissions revoked, site data cleared, app uninstalled). Those are
  terminal: the row is deleted rather than retried, because nothing about it
  will ever work again and a stale row is a delivery attempt per notification
  forever. `403` is treated the same way — it means the VAPID key no longer
  matches the one the subscription was created with, which happens when a
  deployment rotates its pair.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.Push.Vapid

  @doc "Is web push configured on this deployment?"
  @spec enabled?() :: boolean()
  def enabled?, do: Vapid.configured?()

  @doc "The VAPID public key the browser needs to subscribe, or nil when off."
  @spec public_key() :: String.t() | nil
  defdelegate public_key, to: Vapid

  @doc """
  Register (or refresh) a browser's subscription for `actor`.

  An upsert on the endpoint — a browser re-subscribing must move its row, not
  add one, or a device receives a copy of every notification per stale row.
  """
  @spec subscribe(map(), struct(), term()) :: {:ok, struct()} | {:error, term()}
  def subscribe(%{} = params, actor, org) do
    Accounts.subscribe_to_push(
      %{
        user_id: actor.id,
        org_id: org_id(org),
        endpoint: params["endpoint"],
        p256dh: params["p256dh"],
        auth: params["auth"],
        label: label(params["label"])
      },
      authorize?: false
    )
  end

  @doc "Forget one browser's subscription. Scoped to the actor's own rows."
  @spec unsubscribe(String.t(), struct()) :: :ok
  def unsubscribe(endpoint, actor) when is_binary(endpoint) do
    PushSubscription
    |> Ash.Query.for_read(:for_user, %{user_id: actor.id}, actor: actor)
    |> Ash.Query.filter(endpoint == ^endpoint)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))

    :ok
  end

  @doc "The devices `actor` has registered, for the settings page."
  @spec list(struct()) :: [struct()]
  def list(actor), do: Accounts.list_push_subscriptions!(actor.id, actor: actor)

  @doc """
  Enqueue one delivery per subscription belonging to `users`.

  Returns `:ok` whatever happens: a notification that cannot be sent must never
  fail the editorial action that triggered it, which is the same contract
  `KilnCMS.Notifications` has with email.
  """
  @spec notify([struct()], map()) :: :ok
  def notify(users, payload) when is_list(users) and is_map(payload) do
    with true <- enabled?(),
         [_ | _] = ids <- Enum.map(users, & &1.id) do
      ids
      |> subscriptions_for()
      |> Enum.each(&enqueue(&1, payload))
    end

    :ok
  end

  @doc false
  # The sender's read: system-scoped, because the recipients are decided by the
  # workflow rather than by whoever is acting.
  @spec subscriptions_for([Ash.UUID.t()]) :: [struct()]
  def subscriptions_for([]), do: []

  def subscriptions_for(user_ids),
    do: Accounts.push_subscriptions_for!(user_ids, authorize?: false)

  @doc "Delete a subscription a push service has told us is gone."
  @spec prune(struct(), term()) :: :ok
  def prune(subscription, reason) do
    Logger.info("Pruning dead push subscription #{subscription.id}: #{inspect(reason)}")
    Ash.destroy!(subscription, authorize?: false)
    :ok
  end

  defp enqueue(subscription, payload) do
    %{"subscription_id" => subscription.id, "payload" => payload}
    |> KilnCMS.Push.Worker.new()
    |> Oban.insert!()
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id
  defp org_id(_other), do: nil

  # The client sends a coarse browser family; anything else is ignored rather
  # than stored, because this string is rendered back into the settings page.
  defp label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Browser"
      trimmed -> String.slice(trimmed, 0, 60)
    end
  end

  defp label(_absent), do: "Browser"
end
