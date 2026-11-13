defmodule KilnCMS.CMS.Changes.SaverVerifiedSecondFactor do
  @moduledoc """
  The person writing a site's two-step sign-in requirement must hold a second
  factor and prove it now (#2247). On `KilnCMS.CMS.SiteSecondFactorPolicy`'s
  `:save` and `:update`, every write, strengthening included.

  The actor is re-read (a struct loaded before a factor was removed must not
  speak for the account now), and must:

    1. hold a second factor — an authenticator app or a passkey
       (`KilnCMS.Accounts.has_second_factor?/1`); and
    2. either carry a **fresh** verified mark — the changeset context's
       `:second_factor_verified_at`, a `DateTime` no more than 15 minutes old,
       which the console sets from the session's sign-in marker
       (`KilnCMSWeb.SignInMarker`, its `second_factor_at`) — or give the
       `:code` argument: a current code from the actor's authenticator app.

  Why every write and not only weakening: a password-only session on a
  passkey-only admin, or a session signed in before the admin enrolled, could
  otherwise switch the requirement off. Why fresh: a session that verified a
  factor days ago and was left open is not the admin at the keyboard now.

  ## The code is charged before the decision

  A code is checked against the shared second-factor budget
  (`KilnCMS.Accounts.AccountThrottle.consume_second_factor/1`, the one the
  sign-in prompt and `ThrottleSecondFactor` charge) in the change **body**, at
  build time, because a charge made inside the write's transaction is refunded
  by the rollback a wrong code causes (`KilnCMS.Accounts.ThrottleStore`, "Never
  inside a transaction"). Only the actor's own budget is ever charged, so a
  build that authorization then refuses spends nothing but the caller's own
  attempts. A verified code forgives the counter, as at sign-in. Built once per
  submit: an `AshPhoenix.Form` validating on every keystroke would charge per
  keystroke, so a form must pass the code only on submit.

  The decision itself is a `before_action`, after authorization: a person who
  may not write the row at all is told so, not that their factor is missing.

  Refused to anything that is not a person (`nil`, a system actor): the
  operator's way in is `operator_override`, which this change is not on.

  The clock is the server's, unless the changeset context carries `:now` (a
  `DateTime`), which tests set. No request path does.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Errors.SecondFactorThrottled
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User
  alias KilnCMS.Security.Recorder

  # How old a session's second-factor verification may be and still count.
  @fresh_seconds 15 * 60

  # How far ahead of this node's clock a mark may be (another node's clock).
  @skew_seconds 60

  @verdict :second_factor_code_verdict

  @not_enrolled "Set up two-step sign-in on your own account first."
  @not_verified "Confirm with a code from your authenticator app, or sign in again with your passkey."
  @wrong_code "That code isn't valid. Check your authenticator app."

  @doc "How old a verified mark may be, in seconds."
  @spec fresh_seconds() :: pos_integer()
  def fresh_seconds, do: @fresh_seconds

  @doc false
  def messages,
    do: %{not_enrolled: @not_enrolled, not_verified: @not_verified, wrong_code: @wrong_code}

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> charge_code()
    |> Ash.Changeset.before_action(&decide/1, prepend?: true)
  end

  # The code, if any, is checked now: see "The code is charged before the
  # decision". The outcome waits in the context for `decide/1`.
  defp charge_code(changeset) do
    with %User{} = actor <- changeset.context[:private][:actor],
         code when is_binary(code) and code != "" <- Ash.Changeset.get_argument(changeset, :code),
         %User{totp_secret: secret} = user when is_binary(secret) <- reload(actor) do
      Ash.Changeset.set_context(changeset, %{@verdict => check_code(changeset, user, code)})
    else
      _no_code_or_no_app -> changeset
    end
  end

  defp check_code(changeset, user, code) do
    case AccountThrottle.consume_second_factor(user.id) do
      :allow ->
        if Totp.valid?(user.totp_secret, code) do
          AccountThrottle.forgive_second_factor(user.id)
          :verified
        else
          :invalid
        end

      {:deny, retry_after_ms} ->
        alert(user)

        KilnCMS.Security.AuthEvents.locked(
          Map.put(changeset.context, Recorder.tenant_key(), changeset.tenant),
          user,
          "second_factor",
          "settings",
          user.id
        )

        {:deny, retry_after_ms}
    end
  end

  defp decide(changeset) do
    case changeset.context[:private][:actor] do
      %User{} = actor -> decide(changeset, reload(actor))
      _not_a_person -> refuse(changeset, @not_verified)
    end
  end

  defp decide(changeset, %User{} = user) do
    cond do
      not Accounts.has_second_factor?(user) -> refuse(changeset, @not_enrolled)
      fresh?(changeset) -> changeset
      true -> code_verdict(changeset)
    end
  end

  defp decide(changeset, _gone), do: refuse(changeset, @not_enrolled)

  defp code_verdict(changeset) do
    case changeset.context[@verdict] do
      :verified ->
        changeset

      :invalid ->
        refuse(changeset, @wrong_code)

      {:deny, retry_after_ms} ->
        Ash.Changeset.add_error(
          changeset,
          SecondFactorThrottled.exception(
            retry_after_seconds: AccountThrottle.retry_after_seconds(retry_after_ms)
          )
        )

      nil ->
        refuse(changeset, @not_verified)
    end
  end

  defp fresh?(changeset) do
    case changeset.context[:second_factor_verified_at] do
      %DateTime{} = at ->
        age = DateTime.diff(now(changeset), at, :second)
        age >= -@skew_seconds and age <= @fresh_seconds

      _absent ->
        false
    end
  end

  defp refuse(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :code, message: message)

  defp reload(%User{id: id}) do
    # authorize?: false — the actor's own row, re-read by id to see the
    # factors it holds now; nothing read here leaves this module.
    case Accounts.get_user(id, authorize?: false) do
      {:ok, %User{} = user} -> user
      _gone -> nil
    end
  end

  # As `ThrottleSecondFactor`: the owner is told that their live session is
  # being used to guess codes, and the refusal lands whatever the mailer does.
  defp alert(user) do
    KilnCMS.Accounts.SignInAlert.settings_second_factor_locked(user)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp now(changeset) do
    case changeset.context[:now] do
      %DateTime{} = now -> now
      _none -> DateTime.utc_now()
    end
  end
end
