defmodule KilnCMS.Accounts.EnrolmentProof do
  @moduledoc """
  The emailed code a session proves before it adds a second factor, when the
  site requires one and the deadline has passed (#2247, owner decision 1b).

  ## Why

  Once a site holds an account until it sets up a second factor, the set-up
  page is the one thing a held account can reach. Someone who has only the
  password reaches it too, and could add their own authenticator app or
  passkey: the account would then be "enrolled" with a factor its owner does
  not hold. The owner is mailed about every factor added
  (`KilnCMS.Accounts.SecondFactorNotice`), and this is the other half: a
  session that signed in with only a password must first show it can read the
  account's email.

  ## When it is asked for (`decide/4`)

  Only when all of these hold:

    * the account's status on the site is `{:enforced, deadline}`
      (`KilnCMS.Accounts.TwoFactorRequirement.status/3`);
    * the session signed in with a password or a remember-me cookie, or its
      sign-in marker is missing or stale (`KilnCMSWeb.SignInMarker`), or names
      a method this module does not know;
    * it signed in at or after the deadline, or when is unknown.

  A session that signed in by magic link, password reset or confirming a new
  account has already proved the mailbox (`"magic_link_session"`); one that
  signed in through an identity provider (`"sso"`, the site's SSO or the
  operator's OIDC) or with a passkey is not asked (`"not_required"`, decision
  1b). Anything else is not asked either (`"not_required"`): in the grace
  period, a password session from before the deadline, an account the site does
  not hold.

  ## The code

  `send_code/3` mails six digits through the site's relay
  (`KilnCMS.Mail.deliver_now/2`) and returns only an HMAC of them, keyed to
  the account and the session's token, with an expiry ten minutes out. The
  caller keeps that in its own state (a LiveView's assigns): there is no table
  and no stored secret, and the code itself is never returned, logged or
  rendered. At most three are sent to an address an hour
  (`AccountThrottle.allow_mail?(:enrolment_proof, email)`).

  `verify/4` charges the account's second-factor budget
  (`AccountThrottle.consume_second_factor/1`, five per fifteen minutes,
  shared with the code prompt and the settings forms) **before** it compares,
  in constant time, so the six digits cannot be ground. A code verifies for
  the account and session it was sent to, once (the caller drops the pending
  state on success), and not after it expires. What it returns is a signed
  proof, again bound to the account and the session's token, which the
  enrolment actions accept for thirty minutes.

  ## No working relay

  The proof is skipped when the site has no working mail relay (decision 1b):
  `send_code/3` answers `{:skip, :no_relay}`, and the action records
  `"email_skipped_no_relay"`. Only a relay that retrying will not fix counts
  (`KilnCMS.Mail.no_relay?/1`: no outgoing mail server at all, or a site relay
  whose password can no longer be decrypted). A relay that failed this time,
  including a site relay whose settings could not be read just now
  (`{:site_relay, :unavailable}`), is reported as a failure to retry and never
  skips the proof: anyone who could cause a transient failure would otherwise
  get past it.

  ## Enforced on the action, not only the page (`accept/4`)

  `KilnCMS.Accounts.Changes.RequireEnrolmentProof`, on `User.:confirm_totp`
  and `Passkey.:register`, calls `accept/4` with what the page put in the
  action's context (`context/3`). It decides again, from the account and the
  session, and refuses without a valid proof, so a page that skipped its
  proof step, or a forged event, still cannot add a factor. A claimed skip is
  re-checked against `KilnCMS.Mail.relay_available?/1`.
  """
  use KilnCMSWeb, :verified_routes

  require Logger

  import Swoosh.Email

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Mail

  @typedoc """
  The session asking: the jti of its token, and how and when it signed in
  (`KilnCMSWeb.SignInMarker.enrolment_session/1`). `method` is `nil` when
  unknown.
  """
  @type session :: %{
          jti: String.t() | nil,
          method: String.t() | nil,
          signed_in_at: DateTime.t() | nil
        }

  @typedoc "What `send_code/3` hands the caller to keep: never the code."
  @type pending :: %{hash: binary(), expires_at: DateTime.t()}

  @typedoc "The `proof` metadata the enrolment event records."
  @type label :: String.t()

  # Sign-ins that proved the mailbox on the way in.
  @mailbox_methods ~w(magic_link password_reset confirm_new_user)
  # Sign-ins the owner decided not to ask (an identity provider), or that
  # passed a passkey.
  @unasked_methods ~w(sso passkey)
  # Sign-ins that proved only a password.
  @password_methods ~w(password remember_me)

  @code_ttl_seconds 600
  @proof_max_age_seconds 1800
  @proof_salt "second factor enrolment proof"
  @code_key_salt "second factor enrolment proof code"

  @doc """
  Whether `session` must prove the email of `user` before adding a second
  factor on `org_id`: `:required`, or `{:not_needed, label}` with the label
  the enrolment event records. See the moduledoc.

  Options are `TwoFactorRequirement.status/3`'s (`:now`, `:policy`).
  """
  @spec decide(KilnCMS.Accounts.User.t(), Ash.UUID.t() | nil, session() | nil, keyword()) ::
          :required | {:not_needed, label()}
  def decide(user, org_id, session, opts \\ []) do
    case TwoFactorRequirement.status(user, org_id, opts) do
      {:enforced, deadline} -> by_session(session || %{}, deadline)
      _not_held -> {:not_needed, "not_required"}
    end
  end

  defp by_session(%{method: method}, _deadline) when method in @mailbox_methods,
    do: {:not_needed, "magic_link_session"}

  defp by_session(%{method: method}, _deadline) when method in @unasked_methods,
    do: {:not_needed, "not_required"}

  # A password session from before the deadline: the grace let it add a
  # factor without proof then, and it still may.
  defp by_session(%{method: method, signed_in_at: %DateTime{} = at}, deadline)
       when method in @password_methods do
    if DateTime.compare(at, deadline) == :lt,
      do: {:not_needed, "not_required"},
      else: :required
  end

  # A password session with no time, no marker, or a method this module does
  # not know: the weakest case.
  defp by_session(_session, _deadline), do: :required

  @doc "`decide/4` as a boolean."
  @spec required?(KilnCMS.Accounts.User.t(), Ash.UUID.t() | nil, session() | nil, keyword()) ::
          boolean()
  def required?(user, org_id, session, opts \\ []),
    do: decide(user, org_id, session, opts) == :required

  @doc """
  Mail a new code to `user` for `session`, through the relay of `org_id`.

    * `{:ok, pending}` — sent; keep `pending` for `verify/4`;
    * `{:skip, :no_relay}` — the site has no working relay: the proof is
      skipped (see the moduledoc);
    * `{:error, :throttled}` — the address's hourly budget is spent;
    * `{:error, :send_failed}` — the relay failed this time; try again;
    * `{:error, :no_session}` — the session has no token to bind the code to.
  """
  @spec send_code(KilnCMS.Accounts.User.t(), Ash.UUID.t() | nil, session()) ::
          {:ok, pending()}
          | {:skip, :no_relay}
          | {:error, :throttled | :send_failed | :no_session}
  def send_code(user, org_id, %{jti: jti} = session) when is_binary(jti) do
    if AccountThrottle.allow_mail?(:enrolment_proof, to_string(user.email)) do
      code = new_code()

      case Mail.deliver_now(code_email(user, org_id, code), org_id: org_id) do
        {:ok, _receipt} ->
          {:ok,
           %{
             hash: digest(user, session, code),
             expires_at: DateTime.add(DateTime.utc_now(), @code_ttl_seconds, :second)
           }}

        {:error, reason} ->
          failed(user, reason)
      end
    else
      {:error, :throttled}
    end
  end

  def send_code(_user, _org_id, _session), do: {:error, :no_session}

  # The reason is classified, never logged as is: a relay's reply can quote
  # the message, and the message holds the code.
  defp failed(user, reason) do
    if Mail.no_relay?(reason) do
      {:skip, :no_relay}
    else
      Logger.warning(
        "Enrolment proof code for user #{user.id} not sent: #{Mail.failure_kind(reason)}"
      )

      {:error, :send_failed}
    end
  end

  @doc """
  Check `code` against `pending` for `user` and `session`, charging the
  account's second-factor budget first.

    * `{:ok, proof}` — the proof `context/3` carries to the actions;
    * `{:error, :invalid}` — wrong, for another account or session, or no
      code was sent;
    * `{:error, :expired}`;
    * `{:error, {:throttled, retry_after_ms}}` — the budget is spent; nothing
      was compared.
  """
  @spec verify(KilnCMS.Accounts.User.t(), session(), term(), pending() | nil) ::
          {:ok, String.t()}
          | {:error, :invalid | :expired | {:throttled, non_neg_integer()}}
  def verify(user, session, code, pending) do
    case AccountThrottle.consume_second_factor(user.id) do
      {:deny, retry_after_ms} -> {:error, {:throttled, retry_after_ms}}
      :allow -> compare(user, session, code, pending)
    end
  end

  defp compare(user, %{jti: jti} = session, code, %{hash: hash, expires_at: expires_at})
       when is_binary(jti) and is_binary(code) do
    cond do
      not Plug.Crypto.secure_compare(digest(user, session, normalize(code)), hash) ->
        {:error, :invalid}

      DateTime.compare(DateTime.utc_now(), expires_at) != :lt ->
        {:error, :expired}

      true ->
        {:ok, sign_proof(user, jti)}
    end
  end

  defp compare(_user, _session, _code, _pending), do: {:error, :invalid}

  @doc """
  The action context the enrolment actions read: the site, the session, and
  the proof — `verify/4`'s, `:no_relay` after `send_code/3` skipped, or
  `nil`. `org` is the request's org (a struct or its id).
  """
  @spec context(struct() | Ash.UUID.t() | nil, session() | nil, String.t() | :no_relay | nil) ::
          map()
  def context(org, session, proof) do
    %{
      second_factor_enrolment: %{
        org_id: org_id(org),
        session: session,
        proof: proof
      }
    }
  end

  defp org_id(%{id: id}), do: id
  defp org_id(id) when is_binary(id), do: id
  defp org_id(_none), do: nil

  @doc """
  The action-side check (`KilnCMS.Accounts.Changes.RequireEnrolmentProof`):
  `{:ok, label}` when `user` may add a factor on `org_id` from `session` with
  `proof`, `{:error, :proof_required}` otherwise. Decides again rather than
  trusting the page.
  """
  @spec accept(KilnCMS.Accounts.User.t(), Ash.UUID.t() | nil, session() | nil, term()) ::
          {:ok, label()} | {:error, :proof_required}
  def accept(user, org_id, session, proof) do
    case decide(user, org_id, session) do
      {:not_needed, label} -> {:ok, label}
      :required -> proven(user, org_id, session, proof)
    end
  end

  defp proven(user, org_id, session, proof) do
    cond do
      is_binary(proof) and valid_proof?(user, session, proof) -> {:ok, "email"}
      proof == :no_relay and not Mail.relay_available?(org_id) -> {:ok, "email_skipped_no_relay"}
      true -> {:error, :proof_required}
    end
  end

  defp sign_proof(user, jti),
    do: Phoenix.Token.sign(KilnCMSWeb.Endpoint, @proof_salt, %{"u" => user.id, "j" => jti})

  defp valid_proof?(user, %{jti: jti}, proof) when is_binary(jti) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, @proof_salt, proof,
           max_age: @proof_max_age_seconds
         ) do
      {:ok, %{"u" => user_id, "j" => ^jti}} -> user_id == user.id
      _invalid_expired_or_another_session -> false
    end
  end

  defp valid_proof?(_user, _session, _proof), do: false

  # Six digits, uniformly enough: the bias of `rem` over 2^32 is under one in
  # four thousand.
  defp new_code do
    <<n::unsigned-32>> = :crypto.strong_rand_bytes(4)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  defp normalize(code), do: String.replace(code, ~r/\s/, "")

  # Keyed to the deployment, and over the account and the session's token: a
  # code sent to one session does not verify in another, nor for another
  # account.
  defp digest(user, %{jti: jti}, code),
    do: :crypto.mac(:hmac, :sha256, code_key(), "#{user.id}:#{jti}:#{code}")

  defp code_key do
    :secret_key_base
    |> KilnCMSWeb.Endpoint.config()
    |> Plug.Crypto.KeyGenerator.generate(@code_key_salt)
  end

  # Account mail in English, like the other account mail, but sent for and
  # through the site whose requirement asked for it.
  defp code_email(user, org_id, code) do
    site = KilnCMS.Branding.for_org(org_id).site_name

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject("Your code to set up two-step sign-in on #{site}")
    |> html_body("""
    <p>Enter this code to confirm it's you before adding a second factor to your
    #{escape(site)} account:</p>
    <p style="font-size: 1.5em; font-family: monospace; letter-spacing: 0.2em;"><strong>#{code}</strong></p>
    <p>It works for 10 minutes.</p>
    <p><strong>If you didn't ask for this</strong>, someone who knows your password is
    trying to add their own second factor to your account.
    <a href="#{url(~p"/reset")}">Reset your password</a> now: that signs out every session,
    including theirs.</p>
    """)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
