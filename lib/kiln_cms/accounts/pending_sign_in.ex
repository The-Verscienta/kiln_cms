defmodule KilnCMS.Accounts.PendingSignIn do
  @moduledoc """
  The blob that carries "this caller passed the first factor and owes a code"
  between the two halves of a **headless** sign-in (#726).

  The browser flow needs none of this: its equivalent lives in the session, so
  the client never holds it and `AuthController.complete_sign_in/3` destroys it
  by deleting the session key. A headless client has no session, so the state
  has to travel through the client — which changes what it must defend against,
  and is why this is its own module rather than a second call to
  `AuthController.sign_pending/4`.

  ## Encrypted, not signed

  `Phoenix.Token.sign/4` publishes its payload: the base64 body is readable by
  anyone holding the token, the signature only stops it being *changed*. The
  payload here carries the first-factor JWT — already minted and stored by the
  time `AshAuthentication.Strategy.action/3` returned — so signing it would hand
  the caller the very credential the second factor is there to withhold,
  reopening #726 in a shape that looks fixed. `Phoenix.Token.encrypt/4` is
  AES-GCM keyed off `secret_key_base`; the client sees ciphertext.

  Its own salt keeps a browser pending blob and a headless one from being
  interchangeable.

  ## Single use, best-effort

  A redeemed blob is burned, so a captured verify request cannot be replayed —
  and a *successful* request is the one most likely to be sitting in a log, a CI
  transcript or a crash report. The browser flow gets this for free by deleting
  the session key; here it takes a record of what has been spent.

  That record is `Cachex`, node-local, the same trade
  `KilnCMS.Accounts.WebAuthn.take_challenge/1` makes for the passkey ceremony
  and the same one `KilnCMS.Accounts.AccountThrottle` makes for its budgets. It
  is deliberately **fail-open across nodes**: the blob stays independently
  decryptable, so a legitimate client whose two requests are balanced onto
  different nodes still completes, and a replay that lands on a node which never
  saw the redemption still succeeds. On a single-node deployment single use is
  exact; on a cluster it is a strong filter rather than a guarantee.

  The alternative — parking the payload server-side and handing out a bare nonce,
  as `WebAuthn.stash_challenge/1` does — would make it exact and would keep the
  JWT off the client entirely, but it fails *closed* across nodes: two thirds of
  headless sign-ins on a three-node cluster would break. That needs shared state
  to do properly and is tracked separately; breaking a working flow is not a
  price worth paying for the difference.

  Burning is deliberately **not** done on a wrong code or a spent budget. The
  caller has not failed authentication there, and destroying their pending state
  would turn "that code isn't valid" into "start over", which is the browser
  prompt's behaviour too.
  """

  alias KilnCMS.Accounts

  @cache :kiln_cms_pending_sign_ins

  # Distinct from `AuthController`'s `"two-factor pending"`; same five minutes,
  # because it is the same step.
  @salt "api two-factor pending"
  @max_age 300

  @doc "The dedicated Cachex instance for spent blobs (supervised)."
  @spec cache() :: atom()
  def cache, do: @cache

  @doc "How long a minted blob stays redeemable, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  Mint the blob for `user`, who has just passed the first factor.

  `context` is anything `Phoenix.Token` accepts — a conn, socket or endpoint.
  """
  @spec mint(Plug.Conn.t() | Phoenix.Socket.t() | module(), Accounts.User.t()) :: String.t()
  def mint(context, user) do
    Phoenix.Token.encrypt(
      context,
      @salt,
      %{
        "user_id" => user.id,
        "token" => user.__metadata__.token,
        # Names this attempt so redeeming it can be recorded without keeping the
        # ciphertext, which is long and would key the cache on a secret.
        "jti" => 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      },
      # Passed on the *mint* as well as the read. `Plug.Crypto` embeds
      # `Keyword.get(opts, :max_age, 86400)` into the term and `decrypt/4` only
      # *prefers* the reader's value, so without this the blob's own lifetime is
      # a day and the five minutes exists solely at `resolve/2` — one forgetful
      # future reader away from being no bound at all.
      max_age: @max_age
    )
  end

  @doc """
  Resolve a minted blob to the account awaiting its code.

  `{:ok, user, jti}` — with the first-factor token reattached to
  `__metadata__`, so a completed sign-in has something to return — or `:error`
  when the blob is missing, malformed, expired, already spent, or names an
  account that no longer has a second factor.
  """
  @spec resolve(Plug.Conn.t() | Phoenix.Socket.t() | module(), term()) ::
          {:ok, Accounts.User.t(), String.t()} | :error
  def resolve(context, blob) when is_binary(blob) do
    with {:ok, %{"user_id" => user_id, "token" => token} = payload} <-
           Phoenix.Token.decrypt(context, @salt, blob, max_age: @max_age),
         jti when is_binary(jti) <- Map.get(payload, "jti"),
         false <- spent?(jti),
         user when not is_nil(user) <-
           Accounts.get_user!(user_id, authorize?: false, not_found_error?: false),
         # Re-checked rather than trusted from the first step: an account that
         # turned two-factor off in between has no code to verify, and honouring
         # the blob anyway would complete a sign-in on a factor that no longer
         # exists.
         true <- Accounts.totp_enabled?(user) do
      {:ok, %{user | __metadata__: Map.put(user.__metadata__, :token, token)}, jti}
    else
      _ -> :error
    end
  end

  def resolve(_context, _blob), do: :error

  @doc """
  Record this attempt as spent, so the blob cannot be redeemed again.

  Called once the sign-in has actually completed. The marker outlives the blob
  by a second so there is no window in which the blob is still inside its
  `max_age` but the record of its use has expired.
  """
  @spec burn(String.t()) :: :ok
  def burn(jti) when is_binary(jti) do
    Cachex.put(@cache, jti, true, expire: :timer.seconds(@max_age + 1))
    :ok
  end

  defp spent?(jti), do: match?({:ok, true}, Cachex.get(@cache, jti))
end
