defmodule KilnCMS.Accounts.Preparations.CheckBreachedPasswordAtSignIn do
  @moduledoc """
  Looks an administrator's password up in the breach corpus as they sign in
  with it (#2407), on `:sign_in_with_password`, where a site they administer
  asks for it (`KilnCMS.CMS.SitePasswordPolicy`'s `check_on_sign_in`).

  Who is checked and under which policy is
  `KilnCMS.Accounts.PasswordPolicy.sign_in/1`: never an editor or a viewer,
  and the outcome is the strictest policy among the admin orgs with the switch
  on.

    * breached under `:block`: the sign-in is refused with
      `KilnCMS.Accounts.Errors.PasswordResetRequired`. The token
      `SignInPreparation` minted is revoked, no remember-me token is minted,
      and a reset link is mailed (`KilnCMS.Accounts.PasswordResetMail`, best
      effort, within the address's reset-mail budget). The per-account sign-in
      counter is not forgiven, so an owner who keeps trying ends up paused
      like anyone else. The doors send the person to `/reset`. The refusal
      is audited in the orgs whose policy decided it, or in the request's
      site when those cannot be read (#3438).
    * breached under `:warn`: the sign-in goes ahead and the record carries
      `__metadata__.password_breach == %{status: :breached}`. On a browser
      door a `:sign_in` note is left (`KilnCMS.Accounts.PasswordNotice`) for
      the sign-in's completion to show as a flash; the API's one-step `201`
      carries a `password_breach` field.
    * clean, or the lookup could not tell: the sign-in goes ahead. Every
      failure fails open.

  ## One lookup per sign-in, and only for a right password

  An `after_action` hook, declared after `SignInPreparation`,
  `ThrottleSignIn` and `AuditSignIn` and before
  `MaybeGenerateTokenPreparation` (`read_action_after_action_hooks_in_order?`
  runs them in that order). So:

    * a wrong password or an unknown address never reaches it:
      `SignInPreparation`'s hook errors and ends the chain. It also checks the
      record carries the token that hook mints once the password verifies;
    * a throttled or challenged attempt never reaches it: those refuse from a
      `before_action` hook, so the read never runs;
    * a keystroke never reaches it: the sign-in form's `phx-change` builds the
      query and runs no hook;
    * a refusal comes before the remember-me token is minted, and before the
      second-factor prompt: the plaintext exists only at the first factor.

  A read action holds no transaction, so no database connection is held while
  the lookup waits (at most `BreachedPassword.sign_in_deadline/0`).

  Telemetry is `[:kiln_cms, :password, :breach_check]` with `action:
  :sign_in`; nothing identifying the password, the account or the org is
  logged or emitted.
  """
  use Ash.Resource.Preparation

  require Logger

  alias KilnCMS.Accounts.Changes.CheckBreachedPassword
  alias KilnCMS.Accounts.Errors.PasswordResetRequired
  alias KilnCMS.Accounts.PasswordNotice
  alias KilnCMS.Accounts.PasswordPolicy
  alias KilnCMS.Accounts.PasswordResetMail
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Challenge
  alias KilnCMS.Security.Recorder

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, &check/2)
  end

  defp check(query, [record]) do
    with token when is_binary(token) <- signed_in_token(record),
         password when is_binary(password) and password != "" <-
           Ash.Query.get_argument(query, :password),
         {:check, policy, deciding} <- PasswordPolicy.sign_in_decision(record) do
      password
      |> CheckBreachedPassword.lookup_with_policy(:sign_in, policy)
      |> apply_verdict(query, record, token, deciding)
    else
      _not_checked -> {:ok, [record]}
    end
  end

  defp check(_query, records), do: {:ok, records}

  # `Ash.Resource.put_metadata(record, :token, …)` is the last thing
  # `SignInPreparation` does once the password verifies.
  defp signed_in_token(record), do: Map.get(record.__metadata__ || %{}, :token)

  defp apply_verdict(%{outcome: :breached, policy: :block}, query, record, token, deciding) do
    Sessions.revoke_first_factor(token)
    send_reset_mail(record, Map.get(query.context, Recorder.tenant_key()))

    {:error, PasswordResetRequired.exception(org_ids: resolve_deciding(deciding))}
  end

  defp apply_verdict(%{outcome: :breached}, query, record, _token, _deciding) do
    if browser?(query), do: PasswordNotice.put(record.id, :sign_in)
    {:ok, [Ash.Resource.put_metadata(record, :password_breach, %{status: :breached})]}
  end

  defp apply_verdict(_clean_or_unchecked, _query, record, _token, _deciding), do: {:ok, [record]}

  # The browser doors complete the sign-in in `AuthController`, which shows the
  # note; the API answers with the record's metadata instead.
  defp browser?(query) do
    match?(%{surface: :browser}, Map.get(query.context, Challenge.context_key()))
  end

  # Best effort: the refusal stands whether or not the mail goes, and the
  # reset page lets the person ask for another. Nothing identifying is logged.
  defp send_reset_mail(record, tenant) do
    case PasswordResetMail.send(record, tenant, :breached_sign_in) do
      :sent ->
        :ok

      :over_budget ->
        :ok

      {:error, reason} ->
        Logger.warning("breached-password reset mail not sent (#{reason_class(reason)})")
    end
  end

  defp reason_class({:enqueue, _error}), do: :enqueue
  defp reason_class(reason) when is_atom(reason), do: reason

  # The orgs whose policy refused this sign-in, for the audit log. A failed
  # read must not let the sign-in stand: it answers `[]`, and the refusal is
  # audited in the request's site instead (#3438,
  # `KilnCMS.Security.AuthEvents.sign_in_refused_breached/3`).
  defp resolve_deciding(deciding) do
    deciding.()
  rescue
    _error ->
      Logger.warning("breached-password sign-in refusal: deciding sites could not be read")
      []
  end
end
