defmodule KilnCMS.Push.Keys do
  @moduledoc """
  Which VAPID key pair a site's push notifications use (#1560): the site's own
  (`KilnCMS.CMS.SiteVapidKey`, generated at `/editor/site-push`) or the
  deployment's (`KILN_VAPID_*`, `KilnCMS.Push.Vapid.env_keys/0`).

  The one resolver both halves of Web Push ask. `for_org/1` answers the
  subscribe side — which public key the browser is handed — and
  `for_subscription/1` answers the sending side. A push service accepts a
  message only when it is signed by the key the browser subscribed with, so
  the two must never disagree, and they can't: a subscription records the key
  it was made against (`PushSubscription.vapid_public_key`) and is only ever
  signed with that key.

  ## Precedence

    * **A site with its own pair**: new subscriptions on that site are made
      against it.
    * **A site without one**: the deployment's pair, if the operator set one.
      Otherwise push is off for that site until an admin generates a pair.
    * **Existing subscriptions keep their key.** One made against the
      deployment's pair (`vapid_public_key` nil — including every subscription
      from before #1560) is still signed with the deployment's pair after its
      site generates its own, so nobody's notifications stop because an admin
      pressed *Generate*. Re-enabling on a device moves it to the site's key.

  ## Fail direction

  A subscription is signed with its own key or not at all. Signing with
  another key is never a fallback, because the push service rejects it anyway
  (and the worker would read that 403 as a dead subscription).

    * The site's row can't be read (`:unavailable`), or its private key can't be
      decrypted (`:key_unreadable`, after a `SECRET_KEY_BASE` rotation — see
      `docs/secrets-rotation.md`): that site's pushes are **held**, the
      subscriptions kept, and `/editor/site-push` flags it. The subscribe side
      offers no key at all, rather than a public key whose private half is
      gone.
    * The site's row was read and no longer holds the key a subscription was
      made against (`:stale_key`): the key was rotated or removed, the
      subscription can never be delivered to again, and the worker prunes it.
      Rotation deletes those rows itself (`Changes.DropVapidSubscriptions`);
      this covers anything that raced it.
    * A deployment-key subscription with the deployment's keys missing or
      mismatched: held, as before #1560. A bad env var must not delete
      subscriptions.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Push.Vapid

  @type source :: :site | :deployment
  @type error :: :unavailable | :key_unreadable | :stale_key | term()

  @doc """
  The key pair new subscriptions on the site `org_id` are made against, and
  where it came from. `:off` when neither the site nor the deployment has one.
  """
  @spec for_org(Ash.UUID.t() | nil) ::
          {:ok, source(), Vapid.keys()} | :off | {:error, error()}
  def for_org(nil), do: deployment()

  def for_org(org_id) when is_binary(org_id) do
    case read(org_id) do
      {:ok, %{public_key: key} = row} when is_binary(key) -> site(row)
      {:ok, _none} -> deployment()
      :error -> {:error, :unavailable}
    end
  end

  @doc """
  The public key (base64url) the browser on site `org_id` should subscribe
  with, or `nil` when push is off or the site's key is unusable.
  """
  @spec public_key(Ash.UUID.t() | nil) :: String.t() | nil
  def public_key(org_id) do
    case for_org(org_id) do
      {:ok, _source, %{public_b64: key}} -> key
      _off_or_error -> nil
    end
  end

  @doc """
  What to record on a new subscription made against `public_key` on site
  `org_id`: `{:ok, key}` for the site's own key, `{:ok, nil}` for the
  deployment's, or `{:error, :stale_key}` when `public_key` is not the key this
  site hands out now (it was rotated between the page rendering and the
  browser subscribing).
  """
  @spec binding(Ash.UUID.t() | nil, String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, error()}
  def binding(org_id, public_key) do
    case for_org(org_id) do
      {:ok, :site, %{public_b64: ^public_key}} -> {:ok, public_key}
      {:ok, :deployment, %{public_b64: ^public_key}} -> {:ok, nil}
      {:ok, _source, _other_key} -> {:error, :stale_key}
      :off -> {:error, :not_configured}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The key pair to sign a notification to `subscription` with — always the one
  it was made against. See the moduledoc for the errors.
  """
  @spec for_subscription(%{
          required(:org_id) => Ash.UUID.t() | nil,
          required(:vapid_public_key) => String.t() | nil,
          optional(any()) => any()
        }) :: {:ok, Vapid.keys()} | {:error, error()}
  def for_subscription(%{vapid_public_key: nil}), do: Vapid.env_keys()

  # A site key with no site to hold it — nothing can sign for it.
  def for_subscription(%{vapid_public_key: _key, org_id: nil}), do: {:error, :stale_key}

  def for_subscription(%{vapid_public_key: key, org_id: org_id}) when is_binary(key) do
    case read(org_id) do
      {:ok, %{public_key: ^key} = row} ->
        with {:ok, :site, keys} <- site(row), do: {:ok, keys}

      {:ok, _rotated_or_removed} ->
        {:error, :stale_key}

      :error ->
        {:error, :unavailable}
    end
  end

  @doc """
  Whether a site row's private key decrypts — for the settings page, which has
  to say when it doesn't (the row itself still looks fine).
  """
  @spec private_key_readable?(CMS.SiteVapidKey.t()) :: boolean()
  def private_key_readable?(%{public_key: nil}), do: true
  def private_key_readable?(row), do: match?({:ok, :site, _keys}, site(row))

  @doc "A sentence fragment for an `error()`, for logs and the settings page."
  @spec describe_error(error()) :: String.t()
  def describe_error(:unavailable), do: "its push key settings could not be read"

  def describe_error(:key_unreadable),
    do:
      "its private push key could not be decrypted (was SECRET_KEY_BASE rotated?) and must be rotated"

  def describe_error(:stale_key), do: "the key it was made against has been replaced"
  def describe_error(other), do: inspect(other)

  defp deployment do
    case Vapid.env_keys() do
      {:ok, keys} -> {:ok, :deployment, keys}
      {:error, _reason} -> :off
    end
  end

  defp site(%{public_key: public, private_key_encrypted: encrypted} = row) do
    with encrypted when is_binary(encrypted) <- encrypted,
         {:ok, private} <- Vault.decrypt(encrypted),
         {:ok, keys} <- Vapid.load(public, private, subject(row)) do
      {:ok, :site, keys}
    else
      _unreadable -> {:error, :key_unreadable}
    end
  end

  defp subject(%{subject: subject}) when is_binary(subject) and subject != "", do: subject
  defp subject(_row), do: Vapid.subject()

  # The row, `nil` when the site has none, or `:error` when it could not be read.
  #
  # `authorize?: false` — a system read. The push worker has no actor, the
  # subscribe side runs for a reviewer who is not the site's admin, and the
  # read is tenant-scoped to the one site whose key is being used. The private
  # half never leaves this module except as that site's own signing key.
  defp read(org_id) do
    case CMS.list_site_vapid_key(tenant: org_id, authorize?: false) do
      {:ok, [row | _rest]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, error} when is_exception(error) -> unreadable(org_id, Exception.message(error))
      {:error, error} -> unreadable(org_id, inspect(error))
    end
  rescue
    error -> unreadable(org_id, Exception.message(error))
  end

  defp unreadable(org_id, detail) do
    Logger.error("Push key settings for site #{org_id} could not be read: #{detail}")
    :error
  end
end
