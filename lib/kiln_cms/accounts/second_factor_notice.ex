defmodule KilnCMS.Accounts.SecondFactorNotice do
  @moduledoc """
  Tells an account owner that a second factor was added to their account
  (#2247, owner decision 1a): an authenticator app set up or replaced, or a
  passkey registered. One mail per factor added, every time.

  `KilnCMS.Accounts.Changes.NotifyFactorAdded` calls `factor_added/3` after the
  enrollment commits, so a refused or rolled-back enrollment mails nobody. A
  passkey can be added at most `KilnCMS.Accounts.Passkey.max_per_account/0`
  times, a few an hour (`AccountThrottle.consume_passkey_registration/1`),
  which is what keeps "every time" from being a way to flood the owner.

  ## Why the mail is worth sending

  Adding a factor needs a signed-in session and nothing else (a first
  authenticator app asks for no current code, and a passkey asks only for the
  device the person at the keyboard holds). So a stolen session can add one,
  and once it has, the thief can sign in again after the owner's session ends.
  Nothing else tells the owner: no sign-in fails, and the new factor sits in a
  settings list they have no reason to open.

  ## What it says, and what it leaves out

  The kind of factor, when, and the browser, platform and site it was added
  from. Browser and platform are `KilnCMSWeb.UserAgent` families, a fixed
  vocabulary, never the header itself. The mail names no secret, no recovery
  code, no credential id, and not the passkey's name: whoever added it chose
  that name, and an attacker-written line in a mail from the operator's own
  address is a phishing channel (`KilnCMS.Accounts.SignInAlert` makes the same
  call about request data).

  "If this wasn't you" points at a password reset, which signs out every
  session including the thief's, and then at a site admin. Not "sign in and
  remove it": the factor just added may be the only one the account now has,
  and its owner may not be able to get past it to remove it.

  ## Never a failure of the enrollment

  Account mail, so it goes through the instance relay (`Mail.enqueue!/1` with
  no `org_id`), in the operator's branding, in English, like the other account
  mail. Anything that goes wrong is logged and swallowed: the factor is already
  committed, and a mail that cannot be queued must not read as a failed
  enrollment.

  No mail for an erased (anonymized) account: its address is no longer the
  owner's.
  """
  use KilnCMSWeb, :verified_routes

  import Swoosh.Email

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Mail
  alias KilnCMS.Security.Recorder

  @typedoc """
  What was added: an authenticator app (`:added` on a first enrollment,
  `:replaced` over a confirmed one) or a passkey.
  """
  @type factor :: {:totp, :added | :replaced} | :passkey

  @doc """
  Mail the owner of `user_id` that `factor` was added. `context` is the
  action's context: the request (`KilnCMS.Security.Recorder.context_key/0`)
  and the site (`tenant_key/0`) the factor was added from, when the caller
  passed them. Always returns `:ok`.
  """
  @spec factor_added(Ash.UUID.t(), factor(), map()) :: :ok
  def factor_added(user_id, factor, context \\ %{}) do
    case owner(user_id) do
      %User{} = user -> deliver(user, factor, details(context))
      nil -> :ok
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "Second-factor notice for user #{user_id} not sent: #{Exception.message(error)}"
      )

      :ok
  catch
    # A wedged Oban queue or a saturated cache exits rather than raising.
    kind, reason ->
      Logger.warning(
        "Second-factor notice for user #{user_id} not sent: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp owner(user_id) do
    # authorize?: false — reads the account the factor was added to, only to
    # address this notice; the enrolling actor may be a platform admin or the
    # ceremony, and nothing read here reaches them
    case Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %User{anonymized_at: nil} = user} -> user
      _erased_missing_or_unreadable -> nil
    end
  end

  defp deliver(user, factor, details) do
    site = KilnCMS.Branding.for_org(nil).site_name

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(user.email))
    |> subject("A second factor was added to your #{site} account")
    |> html_body(body(escape(site), factor, details))
    |> Mail.enqueue!()
  end

  defp body(site, factor, details) do
    reset = url(~p"/reset")

    """
    <p>#{lead(site, factor)}</p>
    <ul>
    #{Enum.map_join(details, "\n", fn {label, value} -> "  <li>#{label}: #{escape(value)}</li>" end)}
    </ul>
    <p><strong>If this was you</strong>, there is nothing else to do.</p>
    <p><strong>If it wasn't you</strong>, someone is signed in to your account and can now
    use this to sign in again. Do this now:</p>
    <ol>
      <li><a href="#{reset}">Reset your password</a>. That signs out every session,
      including theirs.</li>
      <li>Then ask an administrator of your site to check your account's sign-in methods.
      What was just added may be the only second factor your account has, so you may not be
      able to remove it yourself.</li>
    </ol>
    """
  end

  defp lead(site, {:totp, :added}),
    do: "An authenticator app was set up for two-step sign-in on your #{site} account."

  defp lead(site, {:totp, :replaced}),
    do:
      "A new authenticator app replaced the one your #{site} account used for two-step " <>
        "sign-in. Codes from the old one no longer work."

  defp lead(site, :passkey),
    do:
      "A passkey was added to your #{site} account. A passkey signs in on its own, " <>
        "without your password."

  # When, from what and from where. Each value is ours (a timestamp, a
  # `KilnCMSWeb.UserAgent` family, a site's configured name), never request
  # text, and escaped anyway.
  defp details(context) do
    request = Map.get(context, Recorder.context_key()) || %{}
    %{browser: browser, platform: platform} = KilnCMSWeb.UserAgent.parse(request[:user_agent])

    [
      {"When", Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")},
      {"Browser", device(browser, platform)},
      {"Site", site(Map.get(context, Recorder.tenant_key()))}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp device(nil, nil), do: "an unrecognized browser"
  defp device(browser, nil), do: browser
  defp device(nil, platform), do: "a browser on #{platform}"
  defp device(browser, platform), do: "#{browser} on #{platform}"

  defp site(org_id) when is_binary(org_id), do: KilnCMS.Branding.for_org(org_id).site_name
  defp site(_none), do: nil

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
